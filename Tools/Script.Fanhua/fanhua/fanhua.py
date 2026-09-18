from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import traceback
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

BACKEND_VERSION = "1.0.0"
PROTOCOL_VERSION = 1
PROFILE_VERSION = 1

ZHCONVERT_API = "https://api.zhconvert.org"
ZHCONVERT_REQUEST_INTERVAL = 5.0
ZHCONVERT_TIMEOUT = 120.0
# API 请求体上限为 1 MiB，预留 48 KiB 给 JSON 外壳。
ZHCONVERT_MAX_BODY = 1_000_000

VECTOR_RUN_RE = re.compile(r"[0-9bmlcspnBMLCSPN \t.\-]{500,}")

SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*$")
COMMENT_STAMP_RE = re.compile(
    r"(Comment: Processed by 繁化姬) (\w|-)* @ \d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}"
    r"( \| https://zhconvert.org)")

MAX_LOG_FILES = 20
IRIYA_OUTPUT_LIMIT = 4000

ZHCONVERT_MODULE_KEYS = (
    ("ChineseVariant", "地区词转换"),
    ("Computer", "计算机用语"),
    ("ProperNoun", "专有名词"),
    ("Repeat", "重复词修正"),
    ("RepeatAutoFix", "重复词自动修正"),
    ("Unit", "单位用语"),
)
ZHCONVERT_MODULE_DEFAULT = -1
ZHCONVERT_MODULE_OFF = 0

MISC_DEFAULTS = {
    "chs_suffix": "_CHS",
    "cht_suffix": "_CHT",
    "ignore_styles": "",
    "custom_replacements": "",
    "clean_aegisub": True,
    "auto_metadata": True,
    "auto_comment": True,
    "check_iriya": True,
    "check_matrix": True,
    "check_asterisk": True,
    "generate_diff": True,
    "open_diff": True,
}

ZHCONVERT_DEFAULTS = {
    "modules": {"*": ZHCONVERT_MODULE_OFF},
}

OBSOLETE_ZHCONVERT_KEYS = frozenset({"ignoreTextStyles", "userPostReplace"})


# 错误类型


class FanhuaError(Exception):
    """带「阶段」信息的后端错误。Lua 会直接把它显示给用户。"""

    def __init__(self, stage: str, message: str, detail: str = ""):
        super().__init__(message)
        self.stage = stage
        self.message = message
        self.detail = detail

    def to_payload(self) -> dict:
        return {
            "success": False,
            "protocol_version": PROTOCOL_VERSION,
            "backend_version": BACKEND_VERSION,
            "stage": self.stage,
            "message": self.message,
            "detail": self.detail,
            "traceback": "",
            "error": self.message,
        }


def error_payload(stage: str, exc: BaseException, detail: str = "") -> dict:
    """把任意异常转成 Lua 可显示的错误结果（始终包含 traceback）。"""
    if isinstance(exc, FanhuaError):
        payload = exc.to_payload()
        if detail and not payload["detail"]:
            payload["detail"] = detail
        payload["traceback"] = "".join(
            traceback.format_exception(type(exc), exc, exc.__traceback__))
        return payload
    message = str(exc) or exc.__class__.__name__
    return {
        "success": False,
        "protocol_version": PROTOCOL_VERSION,
        "backend_version": BACKEND_VERSION,
        "stage": stage,
        "message": message,
        "detail": detail,
        "traceback": "".join(
            traceback.format_exception(type(exc), exc, exc.__traceback__)),
        "error": message,
    }


# Profile / 配置


def _as_bool(value, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    text = str(value).strip().lower()
    if text in ("", "default"):
        return default
    if text in ("1", "true", "yes", "y", "on"):
        return True
    if text in ("0", "false", "no", "n", "off"):
        return False
    return default


def _as_text(value) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)


def normalize_modules(raw) -> dict:
    """规范化 zhconvert modules，保留未知 key（向前兼容繁化姬新增模组）。"""
    modules: dict = {}
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except Exception:
            raw = None
    if isinstance(raw, dict):
        for key, value in raw.items():
            try:
                modules[str(key)] = int(value)
            except (TypeError, ValueError):
                modules[str(key)] = value
    if "*" not in modules:
        modules["*"] = ZHCONVERT_MODULE_OFF
    return modules


def module_enabled(modules: dict, key: str) -> bool:
    value = modules.get(key, modules.get("*", ZHCONVERT_MODULE_OFF))
    try:
        return int(value) != 0
    except (TypeError, ValueError):
        return False


def set_module(modules: dict, key: str, enabled: bool) -> dict:
    modules = dict(modules)
    modules[key] = ZHCONVERT_MODULE_DEFAULT if enabled else ZHCONVERT_MODULE_OFF
    return modules


def normalize_profile(raw, warnings: list | None = None) -> dict:
    """把任意来源（旧版 _fanhua.yml / 新 Profile / Lua 传来的表）规范化。

    旧配置只有 misc_config.chs_suffix、cht_suffix 与 zhconvert_config，
    缺失的新字段在这里补默认值，因此旧的 _fanhua.yml 依然可直接使用。
    """
    warn = warnings if warnings is not None else []
    raw = raw if isinstance(raw, dict) else {}

    misc_raw = raw.get("misc_config")
    misc_raw = misc_raw if isinstance(misc_raw, dict) else {}
    zh_raw = raw.get("zhconvert_config")
    zh_raw = zh_raw if isinstance(zh_raw, dict) else {}

    misc = {}
    for key, default in MISC_DEFAULTS.items():
        if key in misc_raw:
            misc[key] = misc_raw[key]
        elif raw.get(key) is not None:
            misc[key] = raw[key]
        else:
            misc[key] = default
            if key not in ("ignore_styles", "custom_replacements"):
                warn.append(f"配置缺少 misc_config.{key}，已使用默认值 {default!r}")

    for key in ("chs_suffix", "cht_suffix"):
        misc[key] = _as_text(misc[key])
    for key in ("ignore_styles", "custom_replacements"):
        misc[key] = _as_text(misc[key]).replace("\r\n", "\n").replace("\r", "\n")
    for key in ("clean_aegisub", "auto_metadata", "auto_comment", "check_iriya",
                "check_matrix", "check_asterisk", "generate_diff", "open_diff"):
        misc[key] = _as_bool(misc[key], MISC_DEFAULTS[key])

    zh = {}
    for key, default in ZHCONVERT_DEFAULTS.items():
        zh[key] = zh_raw.get(key, default)
    for key, value in zh_raw.items():
        if key not in ZHCONVERT_DEFAULTS and key not in OBSOLETE_ZHCONVERT_KEYS:
            zh[key] = value
    zh["modules"] = normalize_modules(zh.get("modules"))

    known = set(MISC_DEFAULTS) | {"misc_config", "zhconvert_config", "profile_version"}
    for key in raw:
        if key not in known:
            warn.append(f"配置中存在未知字段：{key}")

    return {
        "profile_version": int(raw.get("profile_version") or PROFILE_VERSION),
        "misc_config": misc,
        "zhconvert_config": zh,
    }


def parse_ignore_styles(text: str) -> list:
    """每行一个 Style Name，精确匹配（区分大小写），忽略空行。"""
    result = []
    for line in _as_text(text).splitlines():
        name = line.strip()
        if name and name not in result:
            result.append(name)
    return result


def parse_custom_replacements(text: str) -> list:
    """每行「原文=替换后」，只按第一个 = 分割，忽略空行。"""
    rules = []
    for line in _as_text(text).splitlines():
        if not line.strip():
            continue
        if "=" not in line:
            continue
        source, _, target = line.partition("=")
        if source == "":
            continue
        rules.append((source, target))
    return rules


def _str_representer(dumper, data):
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


def load_yaml_module():
    try:
        import yaml
    except Exception as exc:  # pragma: no cover - 取决于运行环境
        raise FanhuaError(
            "config",
            "内置 PyYAML 组件缺失，无法读写配置文件。",
            f"import yaml 失败：{exc}",
        ) from exc
    return yaml


def read_profile_file(path: Path) -> tuple:
    """读取并规范化一个 Profile 文件。返回 (profile, warnings)。"""
    yaml = load_yaml_module()
    if not path.is_file():
        raise FanhuaError("config", f"配置文件不存在：{path.name}", str(path))
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise FanhuaError("config", f"无法读取配置文件：{path.name}", str(exc)) from exc
    try:
        raw = yaml.safe_load(text)
    except Exception as exc:
        raise FanhuaError(
            "config", f"配置文件不是合法的 YAML：{path.name}", str(exc)) from exc
    if raw is not None and not isinstance(raw, dict):
        raise FanhuaError("config", f"配置文件顶层必须是映射：{path.name}", repr(type(raw)))
    warnings: list = []
    profile = normalize_profile(raw or {}, warnings)
    return profile, warnings


def dump_profile_text(profile: dict) -> str:
    yaml = load_yaml_module()
    dumper = yaml.SafeDumper
    dumper.add_representer(str, _str_representer)
    header = (
        "# 由「繁化姬 - Aegisub 内置工具」保存\n"
        "# 可直接手工编辑；GUI 中的「重置」会重新载入本文件。\n"
    )
    body = yaml.dump(
        profile,
        Dumper=dumper,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
        width=4096,
    )
    return header + body


def write_profile_file(path: Path, profile: dict) -> None:
    text = dump_profile_text(profile)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write_text(path, text)
    except OSError as exc:
        raise FanhuaError("config", f"无法写入配置文件：{path.name}", str(exc)) from exc


# 原子写入 / 日志


def atomic_write_text(path: Path, text: str, encoding: str = "utf-8") -> None:
    """先写同目录临时文件，成功后原子替换，失败时清理临时文件。"""
    tmp = path.with_name(f".{path.name}.fanhua-tmp")
    try:
        with open(tmp, "w", encoding=encoding, newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            if tmp.exists():
                tmp.unlink()
        except OSError:
            pass
        raise


def atomic_write_bytes(path: Path, data: bytes) -> None:
    tmp = path.with_name(f".{path.name}.fanhua-tmp")
    try:
        with open(tmp, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            if tmp.exists():
                tmp.unlink()
        except OSError:
            pass
        raise


def default_log_dir() -> Path:
    appdata = os.environ.get("APPDATA")
    base = Path(appdata) if appdata else Path.home()
    return base / "Aegisub" / "fanhua" / "logs"


def prune_logs(log_dir: Path, keep: int = MAX_LOG_FILES) -> None:
    try:
        logs = sorted(
            (entry for entry in log_dir.glob("fanhua-*.log") if entry.is_file()),
            key=lambda entry: entry.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        return
    for stale in logs[keep:]:
        try:
            stale.unlink()
        except OSError:
            pass


def write_log(log_dir: Path | None, entry: dict) -> str:
    """写一份日志。返回日志路径；写日志失败绝不中断主流程。"""
    try:
        directory = Path(log_dir) if log_dir else default_log_dir()
        directory.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = directory / f"fanhua-{stamp}-{os.getpid()}.log"
        entry = dict(entry)
        entry.setdefault("time", time.strftime("%Y-%m-%d %H:%M:%S"))
        entry.setdefault("backend_version", BACKEND_VERSION)
        path.write_text(
            json.dumps(entry, ensure_ascii=False, indent=2, default=str),
            encoding="utf-8",
        )
        prune_logs(directory)
        return str(path)
    except Exception:
        return ""


# ASS 读取与清理


def read_ass(filename, clean: bool = True) -> str:
    """读取 ASS。

    clean=True 时执行与 _fanhua.py 完全一致的清理：
      * 删除 [Aegisub Project Garbage] / [Aegisub Extradata] 区段
      * 删除 motion data  {(=1)(=2)...}
      * 删除 {外:<32 位十六进制>}
    尾部换行归一化在任何模式下都执行（属于 I/O 归一化而非「清理」）。
    """
    contents = ""
    if clean:
        reading = True
        with open(filename, "r", encoding="utf-8") as handle:
            for line in handle:
                if reading:
                    if re.match(r"\[Aegisub Project Garbage\]|\[Aegisub Extradata\]", line):
                        reading = False
                        continue
                    contents += line
                else:
                    if re.match(r"\[V4\+ Styles\]|\[Events\]", line):
                        reading = True
                        contents += line
        contents = re.sub(r"{(=\d*)+}", "", contents)
        contents = re.sub(r"\{外:[\dABCDEF]{32}\}", "", contents)
    else:
        with open(filename, "r", encoding="utf-8") as handle:
            contents = handle.read()

    contents = re.sub(r"([^\n])$", r"\1\n", contents)
    contents = re.sub(r"\n+$", r"\n", contents)
    return contents


def auto_metadata(content: str, filename: Path) -> str:
    """与 _fanhua.py 完全一致。"""
    output = re.sub(
        r"Original Translation: \n|Original Editing: \n|Original Timing: \n"
        r"|Synch Point: \n|Script Updated By: \n|Update Details: \n",
        "", content)
    output = re.sub(r"\nTitle: [^\n]*\n", f"\nTitle: {filename.stem}\n", output)
    if not re.search(r"LayoutResX", output):
        output = re.sub(r"PlayResX: (\d+)", r"PlayResX: \1\nLayoutResX: \1",
                        output, 0, re.MULTILINE)
    if not re.search(r"LayoutResY", output):
        output = re.sub(r"PlayResY: (\d+)", r"PlayResY: \1\nLayoutResY: \1",
                        output, 0, re.MULTILINE)
    return output


def auto_comment(content: str) -> str:
    """与 _fanhua.py 完全一致：依据 Actor 字段中的 chs / cht 切换记录类型。"""
    output = re.sub(
        r"Dialogue: (\d+,\d+:\d{2}:\d{2}\.\d{2},\d+:\d{2}:\d{2}\.\d{2},"
        r"(?P<style>[^,]*),chs,\d+,\d+,\d+,[^,]*,.+\n)", r"Comment: \1", content)
    output = re.sub(
        r"Comment: (\d+,\d+:\d{2}:\d{2}\.\d{2},\d+:\d{2}:\d{2}\.\d{2},"
        r"(?P<style>[^,]*),cht,\d+,\d+,\d+,[^,]*,.+\n)", r"Dialogue: \1", output)
    output = re.sub(
        r"Dialogue: (\d+,\d+:\d{2}:\d{2}\.\d{2},\d+:\d{2}:\d{2}\.\d{2},"
        r"(?P<style>[^,]*),[^,]*,\d+,\d+,\d+,chs,.+\n)", r"Comment: \1", output)
    output = re.sub(
        r"Comment: (\d+,\d+:\d{2}:\d{2}\.\d{2},\d+:\d{2}:\d{2}\.\d{2},"
        r"(?P<style>[^,]*),[^,]*,\d+,\d+,\d+,cht,.+\n)", r"Dialogue: \1", output)
    return output


# Events 解析工具


def iter_lines(content: str) -> list:
    """与 SubtitleDiffWeb.html 的 iterateLines 等价。

    JS 版把 \\r\\n、\\n、\\v、\\f、\\x1c-\\x1e、\\x85、\\u2028、\\u2029 都当作换行，
    Python 的 str.splitlines() 处理集合完全一致，且都不会在结尾追加空行。
    """
    return content.splitlines()


def parse_events_format(content: str) -> list | None:
    """返回 [Events] 中最后一次出现的 Format 字段名（小写）。"""
    fields = None
    in_events = False
    for line in iter_lines(content):
        match = SECTION_RE.match(line.replace("\ufeff", ""))
        if match:
            in_events = match.group(1).strip().lower() == "events"
            if in_events:
                fields = None
            continue
        if not in_events:
            continue
        stripped = line.lstrip()
        if stripped[:7].lower() != "format:":
            continue
        payload = stripped[7:].strip()
        candidate = [part.strip().lower() for part in payload.split(",")]
        if candidate and all(candidate):
            fields = candidate
    return fields


def _split_from_start(value: str, count: int):
    parts = []
    start = 0
    for _ in range(count):
        comma = value.find(",", start)
        if comma < 0:
            return None
        parts.append(value[start:comma])
        start = comma + 1
    parts.append(value[start:])
    return parts


def _split_from_end(value: str, count: int):
    suffix = []
    end = len(value)
    for _ in range(count):
        comma = value.rfind(",", 0, end)
        if comma < 0:
            return None
        suffix.insert(0, value[comma + 1:end])
        end = comma
    return [value[:end]] + suffix


def split_event_fields(payload: str, fields: list):
    """按 Events Format 动态切分一条记录载荷，正确处理 Text 含逗号的情况。"""
    if not fields or "text" not in fields:
        return None
    text_index = fields.index("text")
    prefix = []
    remainder = payload
    if text_index:
        prefix_split = _split_from_start(payload, text_index)
        if not prefix_split or len(prefix_split) != text_index + 1:
            return None
        prefix = prefix_split[:-1]
        remainder = prefix_split[-1]
    suffix_count = len(fields) - text_index - 1
    suffix = []
    text = remainder
    if suffix_count:
        suffix_split = _split_from_end(remainder, suffix_count)
        if not suffix_split or len(suffix_split) != suffix_count + 1:
            return None
        text = suffix_split[0]
        suffix = suffix_split[1:]
    values = prefix + [text] + suffix
    if len(values) != len(fields):
        return None
    return dict(zip(fields, values))


def text_field_span(payload: str, fields: list):
    """返回 payload 中 Text 字段的 (start, end) 字符偏移，失败返回 None。"""
    if not fields or "text" not in fields:
        return None
    text_index = fields.index("text")
    start = 0
    for _ in range(text_index):
        comma = payload.find(",", start)
        if comma < 0:
            return None
        start = comma + 1
    suffix_count = len(fields) - text_index - 1
    end = len(payload)
    for _ in range(suffix_count):
        comma = payload.rfind(",", 0, end)
        if comma < 0:
            return None
        end = comma
    if end < start:
        return None
    return start, end


def event_records(content: str):
    """逐行产出 (index, line, body, eol, kind, payload)；kind 为 dialogue/comment/other。"""
    lines = content.splitlines(keepends=True)
    fields = None
    in_events = False
    for index, line in enumerate(lines):
        body = line.rstrip("\r\n")
        eol = line[len(body):]
        stripped = body.lstrip().replace("\ufeff", "")
        match = SECTION_RE.match(stripped)
        if match:
            in_events = match.group(1).strip().lower() == "events"
            if in_events:
                fields = None
            yield index, line, body, eol, "section", None
            continue
        if not in_events:
            yield index, line, body, eol, "other", None
            continue
        colon = stripped.find(":")
        if colon < 0:
            yield index, line, body, eol, "other", None
            continue
        record_type = stripped[:colon].strip().lower()
        if record_type == "format":
            candidate = [part.strip().lower() for part in stripped[colon + 1:].strip().split(",")]
            if candidate and all(candidate):
                fields = candidate
            yield index, line, body, eol, "format", None
            continue
        if record_type in ("dialogue", "comment"):
            payload = stripped[colon + 1:]
            if payload.startswith(" "):
                payload = payload[1:]
            yield index, line, body, eol, record_type, payload
            continue
        yield index, line, body, eol, "other", None


def rewrite_dialogue_text(content: str, transform) -> tuple:
    """对 Dialogue / Comment 行的 Text 字段做定点改写，其余字节原样保留。

    Text 字段的边界由动态解析出的 Events Format 决定，因此 Text 中含逗号、
    或 Text 不在最后一列都能正确处理。transform 返回 None 表示保持不变。

    transform(record_type, fields, text, line_index) -> str | None
    """
    fields = parse_events_format(content)
    if not fields or "text" not in fields:
        return content, 0
    out = []
    changed = 0
    for index, line, body, eol, kind, payload in event_records(content):
        if kind not in ("dialogue", "comment") or payload is None:
            out.append(line)
            continue
        span = text_field_span(payload, fields)
        parsed = split_event_fields(payload, fields) if span else None
        if span is None or parsed is None:
            out.append(line)
            continue
        start, end = span
        old_text = payload[start:end]
        new_text = transform(kind, parsed, old_text, index)
        if new_text is None or new_text == old_text:
            out.append(line)
            continue
        head = len(body) - len(payload)
        out.append(body[:head] + payload[:start] + new_text + payload[end:] + eol)
        changed += 1
    return "".join(out), changed


# 忽略样式


def mask_ignored_styles(content: str, ignore_styles: list) -> tuple:
    """把被忽略样式的整条 Dialogue 行替换为唯一 token。

    整行替换（而不只是 Text）意味着 Text / Tags / Timing / Actor / Effect /
    Margin / Style 全部逐字节保留，连中文样式名都不会被转换。
    token 独占一行，因此行数不变，zhconvert 的分块行数校验依然成立。
    """
    if not ignore_styles:
        return content, {}
    wanted = set(ignore_styles)
    masked: dict = {}
    out = []
    fields = None
    in_events = False
    for line in content.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        eol = line[len(body):]
        stripped = body.lstrip().replace("\ufeff", "")
        match = SECTION_RE.match(stripped)
        if match:
            in_events = match.group(1).strip().lower() == "events"
            if in_events:
                fields = None
            out.append(line)
            continue
        if in_events:
            lower = stripped.lower()
            if lower.startswith("format:"):
                candidate = [p.strip().lower() for p in stripped[7:].strip().split(",")]
                if candidate and all(candidate):
                    fields = candidate
                out.append(line)
                continue
            if lower.startswith("dialogue:") and fields and "style" in fields:
                payload = stripped[len("dialogue:"):]
                if payload.startswith(" "):
                    payload = payload[1:]
                parsed = split_event_fields(payload, fields)
                if parsed is not None and parsed.get("style", "") in wanted:
                    token = f"__FANHUA_IGNORED_LINE_{len(masked)}__"
                    while token in content:
                        token += "_"
                    masked[token] = body
                    out.append(token + eol)
                    continue
        out.append(line)
    return "".join(out), masked


def restore_masked(content: str, masked: dict, stage: str) -> str:
    for token, original in masked.items():
        count = content.count(token)
        if count != 1:
            raise FanhuaError(
                stage,
                "保护占位符在转换后被改动，已中止以免写坏字幕。",
                f"占位符 {token} 出现 {count} 次（期望 1 次）",
            )
        content = content.replace(token, original)
    return content


# 自定义替换


def apply_rules(text: str, rules: list) -> str:
    for source, target in rules:
        if source and source in text:
            text = text.replace(source, target)
    return text


def replace_outside_tags(text: str, rules: list) -> str:
    """只替换 {...} 之外的可见文字，Override Tag 逐字节不动。"""
    if not rules or not text:
        return text
    out = []
    position = 0
    for match in re.finditer(r"\{[^}]*\}", text):
        out.append(apply_rules(text[position:match.start()], rules))
        out.append(match.group(0))
        position = match.end()
    out.append(apply_rules(text[position:], rules))
    return "".join(out)


def apply_custom_replacements(content: str, rules: list, ignore_styles: list) -> tuple:
    """在 Taiwan 转换之后执行；只改 Dialogue 的可见文字，不碰 Comment / Tag。"""
    if not rules:
        return content, 0
    ignored = set(ignore_styles)

    def transform(kind, parsed, text, index):
        if kind != "dialogue":
            return None
        if parsed.get("style", "") in ignored:
            return None
        return replace_outside_tags(text, rules)

    return rewrite_dialogue_text(content, transform)


# zhconvert


class ZhconvertClient:
    """api.zhconvert.org 客户端。保留 _fanhua.py 的全部保护逻辑。"""

    def __init__(self, interval=None, max_body=None, timeout=None):
        # 运行时读取默认值，便于测试替换模块常量。
        self.interval = ZHCONVERT_REQUEST_INTERVAL if interval is None else interval
        self.max_body = ZHCONVERT_MAX_BODY if max_body is None else max_body
        self.timeout = ZHCONVERT_TIMEOUT if timeout is None else timeout
        self.messages: list = []
        self.request_count = 0

    def _payload(self, text: str, converter: str, config: dict) -> dict:
        return {"text": text, "converter": converter, **config}

    def request(self, payload: dict) -> str:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        if len(body) > self.max_body:
            raise FanhuaError(
                "zhconvert",
                "发送给繁化姬的请求过大。",
                f"payload is too large: {len(body)} bytes",
            )
        start = time.time()
        request = Request(
            f"{ZHCONVERT_API}/convert",
            data=body,
            headers={
                "Content-Type": "application/json; charset=utf-8",
                "User-Agent": "Mozilla/5.0",
            },
        )
        self.request_count += 1
        try:
            with urlopen(request, timeout=self.timeout) as response:
                result = json.load(response)
        except HTTPError as response:
            try:
                message = response.read().decode("utf-8", errors="replace")
            except Exception:
                message = ""
            self.messages.append(
                f"zhconvert HTTP {response.code}: {message[:500]}")
            raise FanhuaError(
                "zhconvert",
                f"繁化姬接口返回 HTTP {response.code}。",
                message[:2000],
            ) from response
        except (URLError, TimeoutError, OSError) as exc:
            self.messages.append(f"zhconvert 网络错误: {exc}")
            raise FanhuaError(
                "zhconvert",
                "无法连接繁化姬接口（网络错误或超时），请检查网络后重试。",
                str(exc),
            ) from exc
        except json.JSONDecodeError as exc:
            raise FanhuaError(
                "zhconvert", "繁化姬接口返回了无法解析的数据。", str(exc)) from exc

        time.sleep(max(0.0, self.interval - (time.time() - start)))
        if result.get("code") != 0:
            raise FanhuaError(
                "zhconvert", "繁化姬接口返回错误。",
                json.dumps(result, ensure_ascii=False)[:2000])
        return result["data"]["text"]

    def convert(self, text: str, converter: str, config: dict) -> str:
        if len(json.dumps(self._payload(text, converter, config),
                          ensure_ascii=False).encode("utf-8")) <= self.max_body:
            return self.request(self._payload(text, converter, config))

        # 长 ASS 绘图与 vector clip 是「转换不变量」的 ASCII，只遮蔽这些串。
        masked: dict = {}

        def mask(match):
            token = f"__FANHUA_VECTOR_{len(masked)}__"
            while token in text:
                token += "_"
            masked[token] = match.group(0)
            return token

        text = VECTOR_RUN_RE.sub(mask, text)
        if len(json.dumps(self._payload(text, converter, config),
                          ensure_ascii=False).encode("utf-8")) <= self.max_body:
            converted = self.request(self._payload(text, converter, config))
        else:
            event_header = re.search(r"^\[Events\]\nFormat:[^\n]*\n", text, re.MULTILINE)
            header = text[:event_header.end()] if event_header else ""
            body = text[len(header):]
            lines = body.splitlines(keepends=True)

            empty_size = len(json.dumps(self._payload("", converter, config),
                                        ensure_ascii=False).encode("utf-8"))

            def escaped_size(value):
                return len(json.dumps(value, ensure_ascii=False).encode("utf-8")) - 2

            room = self.max_body - empty_size - escaped_size(header)
            chunks, current, current_size = [], [], 0
            for line in lines:
                line_size = escaped_size(line)
                if line_size > room:
                    raise FanhuaError(
                        "zhconvert",
                        "存在单行超长的非绘图内容，无法分块发送。",
                        f"one non-vector ASS line is too large ({line_size} bytes)")
                if current and current_size + line_size > room:
                    chunks.append("".join(current))
                    current, current_size = [], 0
                current.append(line)
                current_size += line_size
            if current:
                chunks.append("".join(current))

            self.messages.append(f"zhconvert {converter}: 分 {len(chunks)} 块转换")
            converted_parts = []
            header_lines = len(header.splitlines(keepends=True))
            first_line = header.splitlines()[0] if header else None
            for index, chunk in enumerate(chunks):
                chunk_input = header + chunk
                chunk_output = self.request(self._payload(chunk_input, converter, config))
                if chunk_output.count("\n") != chunk_input.count("\n"):
                    raise FanhuaError(
                        "zhconvert", "分块转换改变了 ASS 行数，已中止。",
                        f"chunk {index + 1}/{len(chunks)}")
                if header and chunk_output.splitlines()[0] != first_line:
                    raise FanhuaError(
                        "zhconvert", "分块转换改变了 ASS 头部结构，已中止。",
                        f"chunk {index + 1}/{len(chunks)}")
                converted_parts.append(
                    chunk_output if index == 0 or not header
                    else "".join(chunk_output.splitlines(keepends=True)[header_lines:]))
            converted = "".join(converted_parts)

        for token, drawing in masked.items():
            if converted.count(token) != 1:
                raise FanhuaError(
                    "zhconvert", "绘图占位符在转换后被改动，已中止。", token)
            converted = converted.replace(token, drawing)
        return converted

    def convert_sctc(self, ass_event_string: str, zhconvert_config: dict) -> tuple:
        """与 _fanhua.py 的 ass_zhconvert_sctc 等价，返回 (wikiTC, twTC)。"""
        no_module = dict(zhconvert_config)
        no_module["modules"] = "{}"
        wiki_tc = self.convert(ass_event_string, "WikiTraditional", no_module)
        tw_tc = self.convert(ass_event_string, "Taiwan", zhconvert_config)
        wiki_tc = COMMENT_STAMP_RE.sub(r"\1\3", wiki_tc)
        tw_tc = COMMENT_STAMP_RE.sub(r"\1\3", tw_tc)
        return wiki_tc, tw_tc


def build_zhconvert_config(zhconvert_config: dict) -> dict:
    """与 _fanhua.py 相同：modules 序列化成 JSON 字符串后随请求发送。"""
    config = {
        key: value for key, value in zhconvert_config.items()
        if key not in OBSOLETE_ZHCONVERT_KEYS
    }
    config["modules"] = str(json.dumps(config.get("modules", {})))
    return config


# 检查项


def check_matrix(content: str) -> dict:
    match = re.search(r"YCbCr Matrix: (.*)\n", content)
    if not match:
        return {
            "ok": False,
            "value": "",
            "message": "YCbCr Matrix 未指定，请确认是否有意为之。",
        }
    value = match.group(1).strip()
    if value != "TV.709":
        return {
            "ok": False,
            "value": value,
            "message": f"YCbCr Matrix = {value}，不是 TV.709，请确认是否有意为之。",
        }
    return {"ok": True, "value": value, "message": ""}


def check_asterisk(content: str) -> dict:
    """找出 {... * ...} 的行，返回具体行号与内容。"""
    lines = []
    for index, line in enumerate(iter_lines(content), start=1):
        if re.search(r"\{[^}]*\*[^{]*\}", line):
            lines.append({"line_number": index, "text": line})
    if lines:
        message = f"发现 {len(lines)} 行包含 {{*}} 特殊标记，请确认。"
    else:
        message = ""
    return {"ok": not lines, "count": len(lines), "lines": lines[:200], "message": message}


def find_iriya() -> Path:
    """iriya.exe 与 fanhua.py 同目录，绝不依赖 PATH。"""
    return Path(__file__).resolve().parent / "iriya.exe"


IRIYA_MISSING_FONT_RE = re.compile(
    r"Font\s+(?P<font>.+?)\s+is either not installed or the default font", re.IGNORECASE)
IRIYA_MISSING_GLYPH_RE = re.compile(
    r"(?P<where>.+?):\s*\[(?P<char>.+?)\]\s*does not exist in\s*(?P<font>.+)$", re.IGNORECASE)


def parse_iriya_report(text: str) -> dict:
    """解析 Iriya 的 stderr 文本。

    Iriya 的退出码只表示「有没有缺字」，字体族缺失只会写一行 WARNING，
    退出码依然是 0。因此这里必须同时解析文本，否则缺字体会被静默放过。
    """
    missing_fonts: list = []
    missing_glyphs: list = []
    for line in iter_lines(text):
        if "WARNING" not in line and "ERROR" not in line:
            continue
        body = line.split(":", 2)[-1].strip() if line.count(":") >= 2 else line.strip()
        match = IRIYA_MISSING_FONT_RE.search(body)
        if match:
            font = match.group("font").strip()
            if font not in missing_fonts:
                missing_fonts.append(font)
            continue
        match = IRIYA_MISSING_GLYPH_RE.search(body)
        if match:
            item = {
                "where": match.group("where").strip(),
                "char": match.group("char"),
                "font": match.group("font").strip(),
            }
            if item not in missing_glyphs:
                missing_glyphs.append(item)
    return {"missing_fonts": missing_fonts, "missing_glyphs": missing_glyphs}


def decode_process_output(data: bytes) -> str:
    """Decode Windows tool output as UTF-8 first, then GB18030."""
    if not data:
        return ""
    for encoding in ("utf-8-sig", "gb18030"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            pass
    return data.decode("utf-8", errors="replace")


def format_missing_fonts(fonts: list) -> str:
    """Format one font name per line for the final report."""
    return "字体未安装：\n" + "\n".join(fonts)


def run_iriya(paths: list) -> dict:
    """非交互地运行 Iriya。组件缺失或失败都只作为 Warning 返回。"""
    executable = find_iriya()
    if not executable.is_file():
        return {
            "ok": False,
            "status": "missing",
            "message": "Iriya 字体检查组件缺失（fanhua/iriya.exe 不存在），已跳过字体检查。",
            "results": [],
            "missing_fonts": [],
            "missing_glyphs": [],
            "stdout": "",
            "stderr": "",
        }

    results = []
    all_fonts: list = []
    all_glyphs: list = []
    for path in paths:
        try:
            completed = subprocess.run(
                [str(executable), str(path)],
                capture_output=True,
                timeout=600,
            )
        except subprocess.TimeoutExpired:
            results.append({"file": Path(path).name, "exit_code": None,
                            "status": "timeout", "message": "Iriya 运行超时。"})
            continue
        except OSError as exc:
            results.append({"file": Path(path).name, "exit_code": None,
                            "status": "error", "message": f"无法启动 Iriya：{exc}"})
            continue

        stdout = decode_process_output(completed.stdout)
        stderr = decode_process_output(completed.stderr)
        report = parse_iriya_report(stderr + "\n" + stdout)
        for font in report["missing_fonts"]:
            if font not in all_fonts:
                all_fonts.append(font)
        for glyph in report["missing_glyphs"]:
            if glyph not in all_glyphs:
                all_glyphs.append(glyph)

        problems = len(report["missing_fonts"]) + len(report["missing_glyphs"])
        if completed.returncode != 0:
            status = "warning"
        elif problems:
            status = "warning"
        else:
            status = "success"
        results.append({
            "file": Path(path).name,
            "exit_code": completed.returncode,
            "status": status,
            "missing_fonts": report["missing_fonts"][:50],
            "missing_glyphs": report["missing_glyphs"][:50],
            "stdout": stdout[-IRIYA_OUTPUT_LIMIT:],
            "stderr": stderr[-IRIYA_OUTPUT_LIMIT:],
        })

    messages = []
    if all_fonts:
        messages.append(format_missing_fonts(all_fonts[:50]))
    if all_glyphs:
        detail = "、".join(
            f"{item['where']} [{item['char']}]→{item['font']}" for item in all_glyphs[:10])
        messages.append(f"缺字 {len(all_glyphs)} 处：{detail}")
    failed = [item for item in results if item["status"] != "success"]
    if failed and not messages:
        messages.append("；".join(
            f"{item['file']}（退出码 {item['exit_code']}）" for item in failed))

    return {
        "ok": not failed,
        "status": "warning" if failed else "success",
        "message": "；".join(messages),
        "results": results,
        "missing_fonts": all_fonts[:50],
        "missing_glyphs": all_glyphs[:50],
        "stdout": "\n".join(item.get("stdout", "") for item in results)[-IRIYA_OUTPUT_LIMIT:],
        "stderr": "\n".join(item.get("stderr", "") for item in results)[-IRIYA_OUTPUT_LIMIT:],
    }


# Diff 引擎（移植自 SubtitleDiffWeb.html，仅比较台词）

DIFF_VERSION = "1.0.0"
MAX_RECORDS = 250000
MAX_REPORT_BYTES = 200 * 1024 * 1024
MAX_MATCH_OPERATIONS = 25000000

ALIGN_PUNCTUATION_RE = re.compile(
    "[\\s\u3000\u3002\uff0c\u3001\uff01\uff1f\u2026\uff5e\u300c\u300d\u300e\u300f"
    "\uff08\uff09()\\[\\]\u3010\u3011:：;；·\\-—–~!?,.\\\"'“”‘’]")

ALIGN_SIMILARITY_THRESHOLD = 0.2
ALIGN_CANDIDATE_LIMIT = 24
ALIGN_POSTING_LIMIT = 80
ALIGN_HIT_LIMIT = 128
ALIGN_BLOCK_LIMIT = 120000
ALIGN_WORK_LIMIT = 20000000

CLEAN_TAG_RE = re.compile(r"\{[^}]*\}")
CLEAN_NEWLINE_RE = re.compile(r"\\[Nn]")
CLEAN_HARDSPACE_RE = re.compile(r"\\h")


def clean_ass_dialogue(value: str) -> str:
    """与 SubtitleDiffWeb.html 的 cleanAssDialogue 完全一致。"""
    value = CLEAN_TAG_RE.sub("", value)
    value = CLEAN_NEWLINE_RE.sub("\n", value)
    value = CLEAN_HARDSPACE_RE.sub(" ", value)
    return value


def make_record(text: str, line_number: int, time_label: str = "", eof_marker: bool = False) -> dict:
    return {
        "text": text,
        "line_number": line_number,
        "time_label": time_label or "",
        "is_eof_marker": bool(eof_marker),
    }


def record_key(record: dict) -> str:
    return json.dumps([bool(record["is_eof_marker"]), record["text"]], ensure_ascii=False)


def parse_ass_dialogues(text: str, display_name: str, side: str = "") -> list:
    """只解析 [Events] 中的 Dialogue。Events Format 完全动态解析。

    与网页版一致：Text 位置由 Format 决定，不假设它在最后一列；
    Text 中的逗号不会被误切；缺少 [Events] / Format / Start / End / Text 都会报错。
    """
    name = str(display_name or "ASS/SSA 文件")
    in_events = False
    found_events = False
    found_format = False
    format_fields = None
    records = []

    for line_number, raw_line in enumerate(iter_lines(text), start=1):
        line = raw_line.lstrip("\ufeff")
        section = SECTION_RE.match(line)
        if section:
            in_events = section.group(1).strip().lower() == "events"
            if in_events:
                found_events = True
                format_fields = None
            continue
        if not in_events:
            continue

        stripped = line.lstrip()
        colon = stripped.find(":")
        if colon < 0:
            continue
        record_type = stripped[:colon].strip().lower()
        payload = stripped[colon + 1:]

        if record_type == "format":
            payload = payload.lstrip()
            fields = [part.strip().lower() for part in payload.split(",")]
            if not fields or any(not field for field in fields):
                raise FanhuaError(
                    "diff",
                    f"{name} 第 {line_number} 行的 Events Format 无效。",
                    f"side={side}")
            if len(set(fields)) != len(fields):
                raise FanhuaError(
                    "diff",
                    f"{name} 第 {line_number} 行的 Events Format 含有重复字段。",
                    f"side={side}")
            for required in ("start", "end", "text"):
                if required not in fields:
                    raise FanhuaError(
                        "diff",
                        f"{name} 的 Events Format 缺少 {required.capitalize()} 字段。",
                        f"side={side}")
            format_fields = fields
            found_format = True
            continue

        if record_type != "dialogue":
            continue
        if payload.startswith(" "):
            payload = payload[1:]
        if format_fields is None:
            raise FanhuaError(
                "diff",
                f"{name} 第 {line_number} 行出现 Dialogue，但此前没有有效的 Events Format。",
                f"side={side}")

        parsed = split_event_fields(payload, format_fields)
        if parsed is None:
            raise FanhuaError(
                "diff",
                f"{name} 第 {line_number} 行的 Dialogue 字段数量与 Events Format 不一致。",
                f"side={side}")

        start = parsed.get("start", "").strip()
        end = parsed.get("end", "").strip()
        records.append(make_record(
            clean_ass_dialogue(parsed.get("text", "")),
            line_number,
            f"{start} → {end}",
            False,
        ))
        if len(records) > MAX_RECORDS:
            raise FanhuaError(
                "diff",
                f"{'右侧' if side == 'right' else '左侧'}文件超过 {MAX_RECORDS:,} 条记录上限。",
                f"side={side}")

    if not found_events:
        raise FanhuaError("diff", f"{name} 缺少 [Events] 区段。", f"side={side}")
    if not found_format:
        raise FanhuaError(
            "diff", f"{name} 的 [Events] 区段缺少有效的 Format 行。", f"side={side}")
    return records


class SequenceMatcher:
    """SubtitleDiffWeb.html 内 SequenceMatcher 的等价实现。

    不直接使用 difflib，是为了保留网页版完全一致的对齐结果与运算量上限。
    """

    def __init__(self, a, b, max_operations: int = MAX_MATCH_OPERATIONS):
        self.a = list(a or [])
        self.b = list(b or [])
        self.max_operations = max(1, int(max_operations) or MAX_MATCH_OPERATIONS)
        self.operations = 0
        self.b2j: dict = {}
        for index, value in enumerate(self.b):
            self.b2j.setdefault(value, []).append(index)
        self.matching_blocks = None
        self.opcodes = None

    def find_longest_match(self, alo: int, ahi: int, blo: int, bhi: int):
        besti, bestj, bestsize = alo, blo, 0
        j2len: dict = {}
        for i in range(alo, ahi):
            newj2len: dict = {}
            for j in self.b2j.get(self.a[i], ()):
                if j < blo:
                    continue
                if j >= bhi:
                    break
                self.operations += 1
                if self.operations > self.max_operations:
                    raise FanhuaError(
                        "diff",
                        "重复内容过多，比较计算量超过安全上限。请拆分文件后重试。",
                        "comparison_too_complex")
                size = j2len.get(j - 1, 0) + 1
                newj2len[j] = size
                if size > bestsize:
                    besti = i - size + 1
                    bestj = j - size + 1
                    bestsize = size
            j2len = newj2len
        while (besti > alo and bestj > blo
               and self.a[besti - 1] == self.b[bestj - 1]):
            besti -= 1
            bestj -= 1
            bestsize += 1
        while (besti + bestsize < ahi and bestj + bestsize < bhi
               and self.a[besti + bestsize] == self.b[bestj + bestsize]):
            bestsize += 1
        return besti, bestj, bestsize

    def get_matching_blocks(self):
        if self.matching_blocks is not None:
            return self.matching_blocks
        queue = [(0, len(self.a), 0, len(self.b))]
        matches = []
        while queue:
            alo, ahi, blo, bhi = queue.pop()
            i, j, size = self.find_longest_match(alo, ahi, blo, bhi)
            if not size:
                continue
            matches.append((i, j, size))
            if alo < i and blo < j:
                queue.append((alo, i, blo, j))
            if i + size < ahi and j + size < bhi:
                queue.append((i + size, ahi, j + size, bhi))
        matches.sort(key=lambda item: (item[0], item[1]))
        collapsed = []
        i1 = j1 = k1 = 0
        for i2, j2, k2 in matches:
            if i1 + k1 == i2 and j1 + k1 == j2:
                k1 += k2
            else:
                if k1:
                    collapsed.append((i1, j1, k1))
                i1, j1, k1 = i2, j2, k2
        if k1:
            collapsed.append((i1, j1, k1))
        collapsed.append((len(self.a), len(self.b), 0))
        self.matching_blocks = collapsed
        return collapsed

    def get_opcodes(self):
        if self.opcodes is not None:
            return self.opcodes
        i = j = 0
        answer = []
        for ai, bj, size in self.get_matching_blocks():
            tag = ""
            if i < ai and j < bj:
                tag = "replace"
            elif i < ai:
                tag = "delete"
            elif j < bj:
                tag = "insert"
            if tag:
                answer.append((tag, i, ai, j, bj))
            i = ai + size
            j = bj + size
            if size:
                answer.append(("equal", ai, i, bj, j))
        self.opcodes = answer
        return answer


def _fragments(kind: str, text: str) -> list:
    return [{"kind": kind, "text": text}] if text else []


def char_diff(left: str, right: str) -> tuple:
    """字符级 Diff，返回 (left_fragments, right_fragments)。"""
    left_characters = list(left)
    right_characters = list(right)
    left_fragments = []
    right_fragments = []
    matcher = SequenceMatcher(left_characters, right_characters)
    for tag, left_start, left_end, right_start, right_end in matcher.get_opcodes():
        left_text = "".join(left_characters[left_start:left_end])
        right_text = "".join(right_characters[right_start:right_end])
        if tag == "equal":
            if left_text:
                left_fragments.append({"kind": "same", "text": left_text})
                right_fragments.append({"kind": "same", "text": right_text})
        elif tag == "delete":
            if left_text:
                left_fragments.append({"kind": "removed", "text": left_text})
        elif tag == "insert":
            if right_text:
                right_fragments.append({"kind": "added", "text": right_text})
        else:
            if left_text:
                left_fragments.append({"kind": "removed", "text": left_text})
            if right_text:
                right_fragments.append({"kind": "added", "text": right_text})
    return left_fragments, right_fragments


def normalize_comparable_text(value) -> str:
    return ALIGN_PUNCTUATION_RE.sub("", "" if value is None else str(value))


def comparable_bigrams(text: str) -> set:
    tokens = set()
    if not text:
        return tokens
    if len(text) < 2:
        tokens.add(text)
        return tokens
    for index in range(1, len(text)):
        tokens.add(text[index - 1] + text[index])
    return tokens


def collect_token_hits(sequence: list, target: float, budget: int, hits: dict) -> int:
    length = len(sequence)
    if length <= budget:
        for offset in sequence:
            hits[offset] = hits.get(offset, 0) + 1
        return budget - length
    low, high = 0, length
    while low < high:
        middle = (low + high) >> 1
        if sequence[middle] < target:
            low = middle + 1
        else:
            high = middle
    below = low - 1
    above = low
    while budget > 0 and (below >= 0 or above < length):
        if above >= length or (below >= 0 and target - sequence[below] <= sequence[above] - target):
            offset = sequence[below]
            below -= 1
        else:
            offset = sequence[above]
            above += 1
        hits[offset] = hits.get(offset, 0) + 1
        budget -= 1
    return budget


def fuzzy_align_records(left, right, left_start, left_end, right_start, right_end, getters) -> list:
    """用 bigram 倒排索引 + 树状数组求最长非交叉链，得到相似度锚点。"""
    left_count = left_end - left_start
    pair_count = right_end - right_start
    if not getters or left_count <= 0 or pair_count <= 0:
        return []
    if left_count > ALIGN_BLOCK_LIMIT or pair_count > ALIGN_BLOCK_LIMIT:
        return []

    field_count = len(getters)
    postings = []
    right_token_counts = []
    right_lengths = []
    for _ in range(field_count):
        postings.append({})
        right_token_counts.append([0] * pair_count)
        right_lengths.append([0] * pair_count)

    for offset in range(pair_count):
        record = right[right_start + offset]
        for field in range(field_count):
            text = normalize_comparable_text(getters[field](record))
            right_lengths[field][offset] = len(text)
            if not text:
                continue
            table = postings[field]
            for token in comparable_bigrams(text):
                table.setdefault(token, []).append(offset)

    posting_limit = max(ALIGN_POSTING_LIMIT, pair_count >> 3)
    for field in range(field_count):
        table = postings[field]
        for token in [token for token, seq in table.items() if len(seq) > posting_limit]:
            del table[token]

    for field in range(field_count):
        counts = right_token_counts[field]
        for sequence in postings[field].values():
            for offset in sequence:
                counts[offset] += 1

    tree_value = [0.0] * (pair_count + 1)
    tree_node = [-1] * (pair_count + 1)
    node_left = []
    node_right = []
    node_previous = []
    node_value = []
    best_node_of_right = [-1] * pair_count

    def query_prefix(position: int):
        value = 0.0
        node = -1
        cursor = position
        while cursor > 0:
            if tree_value[cursor] > value:
                value = tree_value[cursor]
                node = tree_node[cursor]
            cursor -= cursor & -cursor
        return value, node

    def update_point(position: int, value: float, node: int) -> None:
        cursor = position
        while cursor <= pair_count:
            if value > tree_value[cursor]:
                tree_value[cursor] = value
                tree_node[cursor] = node
            cursor += cursor & -cursor

    hits_by_field = [{} for _ in range(field_count)]
    candidate_rank: dict = {}
    left_texts = [""] * field_count
    left_token_counts = [0] * field_count
    work = 0

    for left_index in range(left_start, left_end):
        record = left[left_index]
        candidate_rank.clear()
        expected = ((left_index - left_start) * pair_count) / left_count
        found = False
        for field in range(field_count):
            hits = hits_by_field[field]
            hits.clear()
            budget = ALIGN_HIT_LIMIT
            text = normalize_comparable_text(getters[field](record))
            left_texts[field] = text
            tokens = 0
            if text:
                table = postings[field]
                for token in comparable_bigrams(text):
                    sequence = table.get(token)
                    if not sequence:
                        continue
                    tokens += 1
                    before = budget
                    budget = collect_token_hits(sequence, expected, budget, hits)
                    work += before - budget
                    if budget <= 0:
                        break
            left_token_counts[field] = tokens
            if not hits:
                continue
            found = True
            for offset, count in hits.items():
                candidate_rank[offset] = candidate_rank.get(offset, 0) + count
        if not found:
            continue
        if work > ALIGN_WORK_LIMIT:
            return []

        candidates = list(candidate_rank.keys())
        if len(candidates) > ALIGN_CANDIDATE_LIMIT:
            candidates.sort(key=lambda offset: (
                -candidate_rank.get(offset, 0),
                abs(offset - expected),
                offset,
            ))
            del candidates[ALIGN_CANDIDATE_LIMIT:]
        candidates.sort()

        pending_offset = []
        pending_weight = []
        for offset in candidates:
            best = 0.0
            for field in range(field_count):
                left_text = left_texts[field]
                if not left_text:
                    continue
                hit = hits_by_field[field].get(offset)
                if not hit:
                    continue
                total = left_token_counts[field] + right_token_counts[field][offset]
                if not total:
                    continue
                right_length = right_lengths[field][offset]
                shorter = min(len(left_text), right_length)
                longer = max(len(left_text), right_length)
                score = (2 * hit) / total
                if longer > 0:
                    score *= 0.85 + (0.15 * shorter) / longer
                if score > best:
                    best = score
            if best >= ALIGN_SIMILARITY_THRESHOLD:
                pending_offset.append(offset)
                pending_weight.append(best - ALIGN_SIMILARITY_THRESHOLD)

        pending_previous = []
        pending_total = []
        for cursor in range(len(pending_offset)):
            value, node = query_prefix(pending_offset[cursor])
            pending_previous.append(node)
            pending_total.append(value + pending_weight[cursor])
        for cursor in range(len(pending_offset)):
            offset = pending_offset[cursor]
            existing = best_node_of_right[offset]
            if existing >= 0 and node_value[existing] >= pending_total[cursor]:
                continue
            node = len(node_value)
            node_left.append(left_index)
            node_right.append(right_start + offset)
            node_previous.append(pending_previous[cursor])
            node_value.append(pending_total[cursor])
            best_node_of_right[offset] = node
            update_point(offset + 1, pending_total[cursor], node)

    best = -1
    for offset in range(pair_count):
        node = best_node_of_right[offset]
        if node < 0:
            continue
        if best < 0 or node_value[node] > node_value[best]:
            best = node
    if best < 0:
        return []
    anchors = []
    node = best
    while node >= 0:
        anchors.append((node_left[node], node_right[node]))
        node = node_previous[node]
    anchors.reverse()
    return anchors


def plan_aligned_rows(left, right, key_of, getters) -> list:
    try:
        opcodes = SequenceMatcher([key_of(item) for item in left],
                                  [key_of(item) for item in right]).get_opcodes()
    except FanhuaError as exc:
        if exc.detail != "comparison_too_complex":
            raise
        opcodes = [("replace", 0, len(left), 0, len(right))]

    plan = []
    for tag, left_start, left_end, right_start, right_end in opcodes:
        if tag == "equal":
            for offset in range(left_end - left_start):
                plan.append({"kind": "same", "left": left_start + offset,
                             "right": right_start + offset})
            continue
        anchors = fuzzy_align_records(
            left, right, left_start, left_end, right_start, right_end, getters)
        left_cursor = left_start
        right_cursor = right_start

        def flush_gap(left_cursor, right_cursor, left_stop, right_stop):
            paired = min(left_stop - left_cursor, right_stop - right_cursor)
            for offset in range(paired):
                plan.append({"kind": "pair", "left": left_cursor + offset,
                             "right": right_cursor + offset})
            for offset in range(paired, left_stop - left_cursor):
                plan.append({"kind": "delete", "left": left_cursor + offset, "right": -1})
            for offset in range(paired, right_stop - right_cursor):
                plan.append({"kind": "insert", "left": -1, "right": right_cursor + offset})

        for anchor_left, anchor_right in anchors:
            # 锚点按构造即为单调；跳过失效锚点可保证 plan 里不会出现重复行。
            if anchor_left < left_cursor or anchor_right < right_cursor:
                continue
            flush_gap(left_cursor, right_cursor, anchor_left, anchor_right)
            plan.append({"kind": "pair", "left": anchor_left, "right": anchor_right})
            left_cursor = anchor_left + 1
            right_cursor = anchor_right + 1
        flush_gap(left_cursor, right_cursor, left_end, right_end)
    return plan


def align_records(left, right) -> dict:
    plan = plan_aligned_rows(
        left, right, record_key, [lambda record: ("" if record["is_eof_marker"] else record["text"])])
    rows = []
    block_id = 0
    changed_rows = added_rows = deleted_rows = 0
    previous_was_different = False

    for entry in plan:
        left_record = left[entry["left"]] if entry["left"] >= 0 else None
        right_record = right[entry["right"]] if entry["right"] >= 0 else None
        kind = entry["kind"]
        if kind in ("same", "pair"):
            kind = "equal" if record_key(left_record) == record_key(right_record) else "change"
        if kind == "equal":
            same = _fragments("same", left_record["text"])
            left_fragments = same
            right_fragments = same
        elif kind == "change":
            left_fragments, right_fragments = char_diff(left_record["text"], right_record["text"])
        elif kind == "delete":
            left_fragments = _fragments("removed", left_record["text"])
            right_fragments = []
        else:
            left_fragments = []
            right_fragments = _fragments("added", right_record["text"])

        different = kind != "equal"
        if different and not previous_was_different:
            block_id += 1
        rows.append({
            "left": left_record,
            "right": right_record,
            "kind": kind,
            "left_fragments": left_fragments,
            "right_fragments": right_fragments,
            "block_id": block_id if different else None,
            "block_start": bool(different and not previous_was_different),
        })
        previous_was_different = different
        if kind == "change":
            changed_rows += 1
        elif kind == "insert":
            added_rows += 1
        elif kind == "delete":
            deleted_rows += 1

    return {
        "rows": rows,
        "diff_blocks": block_id,
        "changed_rows": changed_rows,
        "added_rows": added_rows,
        "deleted_rows": deleted_rows,
    }


DIFF_REPORT_CSS = """
:root {
  color-scheme: light;
  --canvas: #f2f6f9;
  --surface: #ffffff;
  --primary: #52759d;
  --primary-strong: #35597f;
  --text: #243142;
  --muted: #6f7c8b;
  --border: #cbd7e0;
  --meta: #edf3f7;
  --changed: #fff2b9;
  --deleted: #f9e2e2;
  --inserted: #e2f3e8;
  --char-del: #eca5a5;
  --char-add: #9ad7aa;
  --accent: #e8f0f6;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  color: var(--text);
  background: var(--canvas);
  font-family: "Segoe UI", "Microsoft YaHei UI", "Microsoft YaHei", sans-serif;
}
.page { width: 100%; margin: 0; padding: 8px; }
.summary {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 7px 12px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  box-shadow: 0 6px 18px rgba(53, 89, 127, .08);
  margin-bottom: 8px;
  padding: 9px 10px;
}
h1 {
  flex: 1 1 30rem;
  color: var(--primary-strong);
  font-size: 20px;
  font-weight: 600;
  line-height: 1.35;
  margin: 0;
}
.report-subtitle { flex-basis: 100%; color: var(--muted); font-size: 12px; margin: -2px 0 0; }
.badges { display: flex; flex-wrap: wrap; align-items: center; gap: 5px; margin: 0; }
.badge { background: var(--accent); border-radius: 999px; padding: 3px 8px; font-size: 12px; white-space: nowrap; }
.badge.changed { background: var(--changed); }
.badge.deleted { background: var(--deleted); }
.badge.inserted { background: var(--inserted); }
.legend { display: flex; flex-wrap: wrap; align-items: center; gap: 9px; color: var(--muted); font-size: 11px; }
.swatch { display: inline-block; width: 12px; height: 12px; border: 1px solid rgba(0,0,0,.15); margin-right: 5px; vertical-align: -2px; }
.swatch.change { background: var(--changed); }
.swatch.delete { background: var(--deleted); }
.swatch.insert { background: var(--inserted); }
.table-wrap {
  width: 100%;
  overflow-x: auto;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  box-shadow: 0 5px 16px rgba(53, 89, 127, .07);
}
table { width: 100%; border-collapse: collapse; table-layout: fixed; }
col.meta-col { width: 10.5rem; }
col.text-col { width: calc(50% - 10.5rem); }
thead th {
  position: sticky;
  top: 0;
  z-index: 5;
  color: #fff;
  background: linear-gradient(135deg, var(--primary), var(--primary-strong));
  border-right: 1px solid rgba(255,255,255,.25);
  padding: 10px 12px;
  text-align: left;
}
.file-name { display: block; font-size: 14px; }
td { border-top: 1px solid var(--border); border-right: 1px solid var(--border); vertical-align: top; }
td.meta { background: var(--meta); color: var(--muted); padding: 7px 8px; font-size: 11px; text-align: right; }
.line-number { display: block; font-variant-numeric: tabular-nums; }
.time-label { display: block; margin-top: 2px; white-space: nowrap; font-variant-numeric: tabular-nums; }
.missing { color: #a5acb7; }
td.content { padding: 7px 9px; background: var(--surface); }
td.content code { display: block; min-height: 1.25em; white-space: pre-wrap; overflow-wrap: anywhere; font: 13px/1.55 Consolas, "Microsoft YaHei UI", monospace; }
tr.row-change td.content { background: var(--changed); }
tr.row-delete td.left-content { background: var(--deleted); }
tr.row-delete td.right-content { background: var(--meta); }
tr.row-insert td.left-content { background: var(--meta); }
tr.row-insert td.right-content { background: var(--inserted); }
.char-removed { background: var(--char-del); border-radius: 2px; }
.char-added { background: var(--char-add); border-radius: 2px; }
.footer { color: var(--muted); font-size: 11px; padding: 12px 2px 2px; text-align: right; }
@media (max-width: 900px) {
  .page { padding: 6px; }
  .summary { border-radius: 9px; }
  h1 { flex-basis: 100%; font-size: 18px; }
  col.meta-col { width: 7rem; }
  col.text-col { width: calc(50% - 7rem); }
  .time-label { white-space: normal; }
}
@media (max-width: 520px) {
  .page { padding: 4px; }
  .summary { gap: 6px; padding: 8px; }
  .legend { flex-basis: 100%; }
}
@media print {
  body { background: #fff; }
  .page { width: 100%; padding: 0; }
  .summary, .table-wrap { box-shadow: none; }
  thead th { position: static; }
}
.report-tools {
  position: sticky;
  bottom: 10px;
  z-index: 20;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 5px 8px;
  width: fit-content;
  max-width: 100%;
  margin: 10px auto 0;
  padding: 7px 10px;
  color: var(--text);
  background: rgba(255, 255, 255, .96);
  border: 1px solid var(--border);
  border-radius: 10px;
  box-shadow: 0 6px 18px rgba(53, 89, 127, .18);
  font-size: 12px;
}
.report-tools button {
  font: inherit;
  padding: 3px 10px;
  color: var(--primary-strong);
  background: var(--accent);
  border: 1px solid var(--border);
  border-radius: 6px;
  cursor: pointer;
}
.report-tools button:hover { background: #dce8f1; }
.report-tools input[type="search"] {
  font: inherit;
  min-width: 10rem;
  padding: 3px 8px;
  color: inherit;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 6px;
}
.report-tools .tool-toggle { display: inline-flex; align-items: center; gap: 5px; cursor: pointer; }
.report-tools .tool-count { color: var(--muted); font-variant-numeric: tabular-nums; }
.report-tools .tool-gap { flex: 1 1 auto; }
body.only-diff tr.row-equal { display: none; }
tr.block-current > td { box-shadow: inset 0 0 0 2px var(--primary); }
tr.search-hit > td { box-shadow: inset 0 0 0 2px #d9a441; }
tr.search-current > td { box-shadow: inset 0 0 0 2px #c8791c; }
@media (max-width: 520px) {
  .report-tools input[type="search"] { min-width: 6rem; }
}
"""

DIFF_REPORT_TOOLS = (
    '<div class="report-tools" role="toolbar" aria-label="差异导航">'
    '<label class="tool-toggle"><input type="checkbox" id="tool-only-diff">只看差异</label>'
    '<button type="button" id="tool-prev">上一处差异</button>'
    '<button type="button" id="tool-next">下一处差异</button>'
    '<span class="tool-count" id="tool-count">0 / 0</span>'
    '<span class="tool-gap"></span>'
    '<input type="search" id="tool-search" placeholder="搜索报告内容…" aria-label="搜索报告内容">'
    '<button type="button" id="tool-search-prev">上一个</button>'
    '<button type="button" id="tool-search-next">下一个</button>'
    '<span class="tool-count" id="tool-search-count"></span>'
    "</div>"
)

DIFF_REPORT_TOOLS_SCRIPT = """
<script>
(function () {
  var blocks = Array.prototype.slice.call(document.querySelectorAll('tr[id^="diff-block-"]'));
  var rows = Array.prototype.slice.call(document.querySelectorAll('tbody tr'));
  var count = document.getElementById('tool-count');
  var toggle = document.getElementById('tool-only-diff');
  var search = document.getElementById('tool-search');
  var searchCount = document.getElementById('tool-search-count');
  var cursor = -1;
  var hits = [];
  var hitCursor = -1;
  function mark(element, className) {
    var previous = document.querySelectorAll('.' + className);
    for (var index = 0; index < previous.length; index += 1) previous[index].classList.remove(className);
    if (!element) return;
    element.classList.add(className);
    element.scrollIntoView({ block: 'center' });
  }
  function showCount() {
    if (count) count.textContent = (cursor + 1) + ' / ' + blocks.length;
  }
  function go(step) {
    if (!blocks.length) return;
    cursor += step;
    if (cursor >= blocks.length) cursor = 0;
    if (cursor < 0) cursor = blocks.length - 1;
    mark(blocks[cursor], 'block-current');
    showCount();
  }
  function goSearch(step) {
    if (!hits.length) return;
    hitCursor += step;
    if (hitCursor >= hits.length) hitCursor = 0;
    if (hitCursor < 0) hitCursor = hits.length - 1;
    mark(hits[hitCursor], 'search-current');
    if (searchCount) searchCount.textContent = (hitCursor + 1) + ' / ' + hits.length + ' 处';
  }
  function runSearch() {
    var needle = search && search.value ? search.value.trim().toLowerCase() : '';
    for (var index = 0; index < hits.length; index += 1) hits[index].classList.remove('search-hit');
    hits = [];
    hitCursor = -1;
    if (needle) {
      for (var rowIndex = 0; rowIndex < rows.length; rowIndex += 1) {
        if (rows[rowIndex].textContent.toLowerCase().indexOf(needle) >= 0) hits.push(rows[rowIndex]);
      }
      for (var hitIndex = 0; hitIndex < hits.length; hitIndex += 1) hits[hitIndex].classList.add('search-hit');
    }
    if (searchCount) searchCount.textContent = needle ? hits.length + ' 处' : '';
    if (hits.length) goSearch(1);
  }
  if (toggle) {
    toggle.addEventListener('change', function () {
      document.body.classList.toggle('only-diff', toggle.checked);
    });
  }
  var prev = document.getElementById('tool-prev');
  var next = document.getElementById('tool-next');
  var searchPrev = document.getElementById('tool-search-prev');
  var searchNext = document.getElementById('tool-search-next');
  if (prev) prev.addEventListener('click', function () { go(-1); });
  if (next) next.addEventListener('click', function () { go(1); });
  if (searchPrev) searchPrev.addEventListener('click', function () { goSearch(-1); });
  if (searchNext) searchNext.addEventListener('click', function () { goSearch(1); });
  if (search) {
    search.addEventListener('input', runSearch);
    search.addEventListener('keydown', function (event) {
      if (event.key === 'Enter') { event.preventDefault(); goSearch(event.shiftKey ? -1 : 1); }
    });
  }
  showCount();
})();
</script>
"""


def escape_html(value) -> str:
    return (str(value)
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
            .replace("'", "&#x27;"))


def render_fragments(items: list) -> str:
    parts = []
    for fragment in items:
        escaped = escape_html(fragment["text"])
        if fragment["kind"] == "removed":
            parts.append(f'<span class="char-removed">{escaped}</span>')
        elif fragment["kind"] == "added":
            parts.append(f'<span class="char-added">{escaped}</span>')
        else:
            parts.append(escaped)
    return "".join(parts) or "&nbsp;"


def render_meta(record) -> str:
    if not record:
        return '<span class="missing">—</span>'
    if record["is_eof_marker"]:
        return '<span class="line-number">EOF</span>'
    details = f'<span class="line-number">行 {record["line_number"]}</span>'
    if record["time_label"]:
        details += f'<span class="time-label">{escape_html(record["time_label"])}</span>'
    return details


ROW_CLASS = {
    "equal": "row-equal",
    "change": "row-change",
    "delete": "row-delete",
    "insert": "row-insert",
}


def row_attributes(row: dict) -> str:
    anchor = (f' id="diff-block-{row["block_id"]}"'
              if row["block_start"] and row["block_id"] is not None else "")
    return f' data-kind="{row["kind"]}"{anchor}'


def build_diff_report(left_name: str, right_name: str, left_records: list,
                      right_records: list, alignment: dict,
                      subtitle: str = "") -> str:
    """生成完全离线的单文件 HTML Diff 报告。"""
    rows_html = "".join(
        f'<tr class="{ROW_CLASS[row["kind"]]}"{row_attributes(row)}>'
        f'<td class="meta">{render_meta(row["left"])}</td>'
        f'<td class="content left-content"><code>{render_fragments(row["left_fragments"])}</code></td>'
        f'<td class="meta">{render_meta(row["right"])}</td>'
        f'<td class="content right-content"><code>{render_fragments(row["right_fragments"])}</code></td>'
        "</tr>"
        for row in alignment["rows"]
    )
    if not rows_html:
        rows_html = ('<tr class="row-equal"><td class="meta">—</td>'
                     '<td class="content"><code>&nbsp;</code></td><td class="meta">—</td>'
                     '<td class="content"><code>&nbsp;</code></td></tr>')

    left_visible = sum(1 for record in left_records if not record["is_eof_marker"])
    right_visible = sum(1 for record in right_records if not record["is_eof_marker"])
    title = "繁化差异报告"
    head_title = f"{title} · {left_name} → {right_name}"
    subtitle_html = f'<p class="report-subtitle">{escape_html(subtitle)}</p>' if subtitle else ""
    footer = (f"由 繁化姬 Fanhua Diff {DIFF_VERSION} 生成 · "
              "仅比较 Dialogue 可见台词 · 报告完全离线且不含外部资源")

    return f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape_html(head_title)}</title>
<style>{DIFF_REPORT_CSS}</style>
</head>
<body>
<main class="page">
  <section class="summary">
    <h1>{escape_html(title)}</h1>
    {subtitle_html}
    <div class="badges">
      <span class="badge">差异块：{alignment["diff_blocks"]}</span>
      <span class="badge changed">修改：{alignment["changed_rows"]}</span>
      <span class="badge deleted">删除：{alignment["deleted_rows"]}</span>
      <span class="badge inserted">新增：{alignment["added_rows"]}</span>
      <span class="badge">左侧记录：{left_visible}</span>
      <span class="badge">右侧记录：{right_visible}</span>
    </div>
    <div class="legend">
      <span><i class="swatch change"></i>修改</span>
      <span><i class="swatch delete"></i>左侧独有/删除</span>
      <span><i class="swatch insert"></i>右侧独有/新增</span>
    </div>
  </section>
  <div class="table-wrap">
    <table aria-label="字幕繁化差异比较">
      <colgroup>
        <col class="meta-col"><col class="text-col">
        <col class="meta-col"><col class="text-col">
      </colgroup>
      <thead>
        <tr>
          <th colspan="2"><span class="file-name">左侧：{escape_html(left_name)}</span></th>
          <th colspan="2"><span class="file-name">右侧：{escape_html(right_name)}</span></th>
        </tr>
      </thead>
      <tbody>{rows_html}</tbody>
    </table>
  </div>
  <div class="footer">{escape_html(footer)}</div>
  {DIFF_REPORT_TOOLS}
</main>
{DIFF_REPORT_TOOLS_SCRIPT}
</body>
</html>
"""


def build_dialogue_diff_report(left_text: str, right_text: str,
                               left_name: str = "WikiTraditional",
                               right_name: str = "Taiwan",
                               subtitle: str = "") -> tuple:
    """「仅比较台词」模式：解析 → 对齐 → 渲染。返回 (html, stats)。"""
    left_records = parse_ass_dialogues(left_text, left_name, "left")
    right_records = parse_ass_dialogues(right_text, right_name, "right")
    alignment = align_records(left_records, right_records)
    html = build_diff_report(left_name, right_name, left_records, right_records,
                             alignment, subtitle)
    size = len(html.encode("utf-8"))
    if size > MAX_REPORT_BYTES:
        raise FanhuaError(
            "diff", "生成的报告超过 200 MiB 上限，请拆分字幕文件后重试。",
            f"{size} bytes")
    stats = {
        "diff_blocks": alignment["diff_blocks"],
        "changed_rows": alignment["changed_rows"],
        "added_rows": alignment["added_rows"],
        "deleted_rows": alignment["deleted_rows"],
        "left_records": sum(1 for record in left_records if not record["is_eof_marker"]),
        "right_records": sum(1 for record in right_records if not record["is_eof_marker"]),
        "report_bytes": size,
    }
    return html, stats


# 请求解析


def build_settings(request: dict) -> tuple:
    """把 Lua 传来的 request 归一化成 (misc, zhconvert, warnings)。

    支持两种形态，并且以「扁平字段」优先（对应 任务要求.txt 第十五节）：
      * request.profile           = 完整 Profile（misc_config + zhconvert_config）
      * request.<扁平字段>         = chs_suffix / ignore_styles / ... 单项覆盖
    """
    warnings: list = []
    profile = request.get("profile")
    if isinstance(profile, dict) and (
            "misc_config" in profile or "zhconvert_config" in profile):
        normalized = normalize_profile(profile, warnings)
    else:
        normalized = normalize_profile({}, warnings)
    misc = normalized["misc_config"]
    zh = normalized["zhconvert_config"]

    for key, default in MISC_DEFAULTS.items():
        if key not in request or request[key] is None:
            continue
        value = request[key]
        if isinstance(default, bool):
            misc[key] = _as_bool(value, misc[key])
        else:
            misc[key] = _as_text(value).replace("\r\n", "\n").replace("\r", "\n")

    if isinstance(request.get("zhconvert_config"), dict):
        for key, value in request["zhconvert_config"].items():
            if key not in OBSOLETE_ZHCONVERT_KEYS:
                zh[key] = value
    if request.get("zhconvert_modules"):
        zh["modules"] = normalize_modules(request["zhconvert_modules"])
    else:
        zh["modules"] = normalize_modules(zh.get("modules"))

    return misc, zh, warnings


def _safe_unlink(path: Path) -> None:
    try:
        if path.exists():
            path.unlink()
    except OSError:
        pass


# 主流程


def process(request: dict) -> dict:
    """执行完整繁化流程。任何异常都会被转成 Lua 可显示的错误结果。"""
    started = time.time()
    stage = "启动"
    log_dir = request.get("log_dir")
    log_entry: dict = {
        "profile": request.get("profile_name") or "",
        "input": request.get("input_file") or "",
        "stages": [],
    }
    written: list = []

    def note(stage_name: str) -> None:
        nonlocal stage
        stage = stage_name
        log_entry["stages"].append({"stage": stage_name, "at": round(time.time() - started, 3)})

    try:
        note("检查协议")
        version = request.get("protocol_version")
        if version is None:
            version = PROTOCOL_VERSION
        if int(version) != PROTOCOL_VERSION:
            raise FanhuaError(
                "检查协议",
                f"前后端协议版本不一致：Lua={version}，Python={PROTOCOL_VERSION}。"
                "请重新完整安装插件。",
                "protocol_version mismatch",
            )

        note("读取配置")
        misc, zh_config, config_warnings = build_settings(request)
        log_entry["profile_name"] = request.get("profile_name") or ""

        note("检查输入")
        raw_input = request.get("input_file") or ""
        if not raw_input:
            raise FanhuaError("检查输入", "没有取得当前 ASS 文件路径。", "input_file 为空")
        input_file = Path(raw_input)
        if not input_file.is_file():
            raise FanhuaError(
                "检查输入", f"找不到当前 ASS 文件：{input_file.name}", str(input_file))
        log_entry["input"] = str(input_file)

        note("检查输出路径")
        chs_path = input_file.with_stem(input_file.stem + misc["chs_suffix"])
        cht_path = input_file.with_stem(input_file.stem + misc["cht_suffix"])
        diff_path = input_file.with_name(input_file.stem + ".diff.html")
        for target, label in ((chs_path, "简体"), (cht_path, "繁体")):
            if target.resolve() == input_file.resolve():
                raise FanhuaError(
                    "检查输出路径",
                    f"{label}输出路径与原始 ASS 相同，为避免覆盖原文件已中止。",
                    "请修改简体/繁体后缀设置。",
                )
        if chs_path.resolve() == cht_path.resolve():
            raise FanhuaError(
                "检查输出路径",
                "简体后缀与繁体后缀相同，两个输出会互相覆盖，已中止。",
                "请修改简体/繁体后缀设置。",
            )

        ignore_styles = parse_ignore_styles(misc["ignore_styles"])
        rules = parse_custom_replacements(misc["custom_replacements"])

        note("读取 ASS")
        # raw_source 保留原始行号，供 {*} 检查回报「用户打开的那份 ASS 里的第几行」。
        raw_source = read_ass(input_file, clean=False)
        contents = read_ass(input_file, clean=misc["clean_aegisub"])

        note("整理 Metadata")
        if misc["auto_metadata"]:
            contents = auto_metadata(contents, input_file)

        note("保护忽略样式")
        masked_input, masks = mask_ignored_styles(contents, ignore_styles)
        log_entry["ignored_lines"] = len(masks)
        log_entry["ignore_styles"] = ignore_styles

        note("繁化姬转换")
        client = ZhconvertClient()
        wiki_raw, tw_raw = client.convert_sctc(
            masked_input, build_zhconvert_config(zh_config))
        log_entry["zhconvert_requests"] = client.request_count

        note("还原忽略样式")
        wiki_tc = restore_masked(wiki_raw, masks, "繁化姬转换")

        note("自定义替换")
        tw_custom, replaced = apply_custom_replacements(tw_raw, rules, ignore_styles)
        tw_tc = restore_masked(tw_custom, masks, "自定义替换")
        log_entry["custom_replacements"] = len(rules)
        log_entry["custom_replaced_lines"] = replaced

        note("生成 Diff")
        diff_html = ""
        diff_stats: dict = {}
        if misc["generate_diff"]:
            diff_html, diff_stats = build_dialogue_diff_report(
                wiki_tc, tw_tc,
                left_name="WikiTraditional",
                right_name="Taiwan",
                subtitle=f"{input_file.name} · 繁化差异（Taiwan + 自定义替换）",
            )

        note("自动切换简繁注释")
        cht_text = tw_tc
        if not cht_text.startswith("\ufeff"):
            cht_text = "\ufeff" + cht_text
        if misc["auto_comment"]:
            cht_text = auto_comment(cht_text)

        note("写入输出")
        try:
            atomic_write_text(chs_path, contents)
            written.append(chs_path)
            atomic_write_text(cht_path, cht_text)
            written.append(cht_path)
            if diff_html:
                atomic_write_text(diff_path, diff_html)
                written.append(diff_path)
        except OSError as exc:
            raise FanhuaError(
                "写入输出", f"无法写入输出文件：{exc.strerror or exc}", str(exc)) from exc

        note("字幕检查")
        warnings = {
            "config": {"ok": not config_warnings, "messages": config_warnings},
            "zhconvert": {"ok": True, "messages": client.messages},
        }
        if misc["check_matrix"]:
            warnings["matrix"] = check_matrix(contents)
        else:
            warnings["matrix"] = {"ok": True, "value": "", "message": "", "skipped": True}
        if misc["check_asterisk"]:
            warnings["asterisk"] = check_asterisk(raw_source)
        else:
            warnings["asterisk"] = {"ok": True, "count": 0, "lines": [],
                                    "message": "", "skipped": True}
        if misc["check_iriya"]:
            warnings["iriya"] = run_iriya([chs_path, cht_path])
        else:
            warnings["iriya"] = {"ok": True, "status": "skipped", "message": "",
                                 "results": [], "stdout": "", "stderr": ""}

        note("完成")
        result = {
            "success": True,
            "protocol_version": PROTOCOL_VERSION,
            "backend_version": BACKEND_VERSION,
            "stage": "",
            "message": "",
            "detail": "",
            "error": None,
            "outputs": {
                "chs": str(chs_path),
                "cht": str(cht_path),
                "diff": str(diff_path) if diff_html else "",
            },
            "output_names": {
                "chs": chs_path.name,
                "cht": cht_path.name,
                "diff": diff_path.name if diff_html else "",
            },
            "stats": diff_stats,
            "warnings": warnings,
            "zhconvert_requests": client.request_count,
            "elapsed": round(time.time() - started, 3),
        }
        log_entry.update({
            "result": "success",
            "outputs": result["outputs"],
            "stats": diff_stats,
            "warnings": {
                key: value.get("message", "")
                for key, value in warnings.items() if isinstance(value, dict)
            },
            "elapsed": result["elapsed"],
        })
        result["log_file"] = write_log(log_dir, log_entry)
        return result

    except BaseException as exc:  # noqa: BLE001 - 必须兜住一切，绝不静默退出
        for path in written:
            _safe_unlink(path)
        log_entry.update({
            "result": "failed",
            "stage": stage,
            "error": str(exc),
            "traceback": "".join(
                traceback.format_exception(type(exc), exc, exc.__traceback__)),
            "elapsed": round(time.time() - started, 3),
        })
        payload = error_payload(stage, exc)
        # 管线阶段名对用户更有意义（例如「繁化姬转换」而不是内部名 zhconvert）
        payload["stage"] = stage
        payload["log_file"] = write_log(log_dir, log_entry)
        payload["elapsed"] = log_entry["elapsed"]
        return payload


# 入口 / JSON 协议


def load_json_file(path: Path) -> dict:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise FanhuaError("请求", f"无法读取请求文件：{path.name}", str(exc)) from exc
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise FanhuaError("请求", f"请求文件不是合法 JSON：{path.name}", str(exc)) from exc
    if not isinstance(data, dict):
        raise FanhuaError("请求", "请求文件的顶层必须是 JSON 对象。", path.name)
    return data


def save_json_file(path: Path, payload: dict) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write_bytes(
            path, json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8"))
    except OSError as exc:
        raise FanhuaError("结果", f"无法写入结果文件：{path.name}", str(exc)) from exc


def handle_profile_read(args) -> dict:
    profile_path = Path(args.profile_read)
    warnings: list = []
    try:
        profile, warnings = read_profile_file(profile_path)
        return {
            "success": True,
            "protocol_version": PROTOCOL_VERSION,
            "backend_version": BACKEND_VERSION,
            "path": str(profile_path),
            "name": profile_path.stem,
            "profile": profile,
            "warnings": {"config": {"ok": not warnings, "messages": warnings}},
            "error": None,
        }
    except BaseException as exc:  # noqa: BLE001
        payload = error_payload("读取配置", exc)
        payload["path"] = str(profile_path)
        payload["name"] = profile_path.stem
        return payload


def handle_profile_write(args) -> dict:
    request_path = Path(args.profile_write)
    try:
        request = load_json_file(request_path)
    except BaseException as exc:  # noqa: BLE001
        return error_payload("写入配置", exc)

    output = args.output
    if not output:
        return error_payload(
            "写入配置", FanhuaError("写入配置", "缺少 --output 参数。"))
    output_path = Path(output)
    warnings: list = []
    try:
        profile = normalize_profile(
            request.get("profile") if isinstance(request.get("profile"), dict) else request,
            warnings)
        write_profile_file(output_path, profile)
        return {
            "success": True,
            "protocol_version": PROTOCOL_VERSION,
            "backend_version": BACKEND_VERSION,
            "path": str(output_path),
            "name": output_path.stem,
            "profile": profile,
            "warnings": {"config": {"ok": not warnings, "messages": warnings}},
            "error": None,
        }
    except BaseException as exc:  # noqa: BLE001
        payload = error_payload("写入配置", exc)
        payload["path"] = str(output_path)
        return payload


def handle_profile_list(args) -> dict:
    """枚举配置目录中可用的 Profile（Lua 侧没有 lfs 时的回退路径）。"""
    try:
        request = load_json_file(Path(args.profile_list))
    except BaseException as exc:  # noqa: BLE001
        return error_payload("枚举配置", exc)

    directory = request.get("config_dir")
    if not directory:
        return error_payload(
            "枚举配置", FanhuaError("枚举配置", "请求缺少 config_dir。"))
    path = Path(directory)
    profiles: list = []
    try:
        if path.is_dir():
            for entry in sorted(path.iterdir()):
                if not entry.is_file():
                    continue
                suffix = entry.suffix.lower()
                if suffix in (".yml", ".yaml") and entry.stem:
                    profiles.append(entry.stem)
    except OSError as exc:
        return error_payload(
            "枚举配置", FanhuaError("枚举配置", f"无法读取配置目录：{path}", str(exc)))
    return {
        "success": True,
        "protocol_version": PROTOCOL_VERSION,
        "backend_version": BACKEND_VERSION,
        "config_dir": str(path),
        "profiles": profiles,
        "error": None,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fanhua.py",
        description="繁化姬 - Aegisub Automation Python 后端（非交互）",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--process", metavar="REQUEST_JSON",
                       help="执行繁化流程，读取 request JSON")
    group.add_argument("--profile-read", metavar="PROFILE_YML",
                       help="读取并规范化一个 Profile YAML")
    group.add_argument("--profile-write", metavar="REQUEST_JSON",
                       help="把 request 中的 profile 写入 --output 指定的 YAML")
    group.add_argument("--profile-list", metavar="REQUEST_JSON",
                       help="枚举 config_dir 中的 Profile 名称")
    parser.add_argument("--output", metavar="PATH", help="--profile-write 的目标 YAML")
    parser.add_argument("--result", metavar="PATH", help="result JSON 输出路径")
    parser.add_argument("--log-dir", metavar="PATH", help="日志目录")
    parser.add_argument("--console", action="store_true",
                        help="额外把结果摘要写到 stdout（仅供开发调试，IPC 不依赖 stdout）")
    parser.add_argument("--version", action="version",
                        version=f"fanhua.py {BACKEND_VERSION} (protocol {PROTOCOL_VERSION})")
    return parser


def result_path_for(args) -> Path:
    if args.result:
        return Path(args.result)
    for value in (args.process, args.profile_write, args.profile_list):
        if value:
            return Path(value).with_suffix(".result.json")
    return Path(args.profile_read).with_suffix(".result.json")


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    result_path = result_path_for(args)

    try:
        if args.process:
            request = load_json_file(Path(args.process))
            if args.log_dir and not request.get("log_dir"):
                request["log_dir"] = args.log_dir
            payload = process(request)
        elif args.profile_read:
            payload = handle_profile_read(args)
        elif args.profile_list:
            payload = handle_profile_list(args)
        else:
            payload = handle_profile_write(args)
    except BaseException as exc:  # noqa: BLE001
        payload = error_payload("启动", exc)

    try:
        save_json_file(result_path, payload)
    except BaseException as exc:  # noqa: BLE001
        payload = error_payload("结果", exc)
        try:
            result_path.parent.mkdir(parents=True, exist_ok=True)
            result_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        except BaseException:
            pass

    # pythonw.exe 下 sys.stdout 可能是 None，绝不能因此抛异常
    if args.console and sys.stdout is not None:
        try:
            summary = {
                "success": payload.get("success"),
                "stage": payload.get("stage", ""),
                "message": payload.get("message", ""),
                "outputs": payload.get("outputs", {}),
                "result": str(result_path),
            }
            sys.stdout.write(json.dumps(summary, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        except Exception:
            pass

    return 0 if payload.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
