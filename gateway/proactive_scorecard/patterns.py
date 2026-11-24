from __future__ import annotations

import re
import unicodedata

from gateway.proactive_scorecard.rubric import Criterion

_TRAILING_NOISE = re.compile(r"[\s\*_`~\)\]\"'”’»>☀-➿\U0001f000-\U0001faff️]+$")
_OPTION_LINE = re.compile(r"^\s*(?:[-*•]|\d{1,2}[.)]|[A-Da-d][.)])\s+\S")
_LAST_PARAGRAPH_CHARS = 600


def fold(text: str) -> str:
    stripped = unicodedata.normalize("NFD", text.lower().replace("đ", "d"))
    return "".join(ch for ch in stripped if not unicodedata.combining(ch))


def _compile(*patterns: str) -> tuple[re.Pattern, ...]:
    return tuple(re.compile(p, re.IGNORECASE) for p in patterns)


CRITERIA_PATTERNS: dict[Criterion, tuple[re.Pattern, ...]] = {
    Criterion.OWNER_ONLY: _compile(
        r"\b(password|passcode|api key|token|credential|secret|2fa|otp)\b",
        r"\byour (budget|address|phone|birthday|deadline|preference|taste|opinion|schedule|availability)\b",
        r"\bwhat do you (want|prefer|like)\b",
        r"\bwhich (do|would) you (prefer|want|like)\b",
        r"\b(mat khau|ngan sach|so dien thoai|dia chi cua ban|ban (muon|thich) (cai nao|gi))\b",
    ),
    Criterion.IRREVERSIBLE: _compile(
        r"\b(delete|drop|wipe|erase|force[- ]push|publish|deploy|merge|release|overwrite)\b",
        r"\bsend (it|this|the|that|an?) (email|mail|message|dm|reply|proposal|invoice)\b",
        r"\b(cannot|can't|can not) be undone\b",
        r"\b(xoa|gui (email|mail|tin nhan)|dang bai|trien khai|khong the hoan tac)\b",
    ),
    Criterion.COSTLY: _compile(
        r"\b(pay|purchase|buy|charge|subscribe|spend|upgrade (the )?plan|\$\d+|usd)\b",
        r"\b(thanh toan|mua|tra tien|chi tieu|nang cap goi)\b",
    ),
    Criterion.APPROVAL_GATE: _compile(
        r"\b(approve|approval|sign[- ]?off|ok to send|good to send|send it now)\b",
        r"\b(duyet|phe duyet|cho phep gui)\b",
    ),
    Criterion.LOOKUP_DECIDABLE: _compile(
        r"\bwhat('?s| is) the (path|file ?name|filename|version|url|link|name|branch|command|error|status)\b",
        r"\bwhich (file|folder|directory|branch|repo|version|model|effort|tool)\b",
        r"\b(where is|where are|where do i find)\b",
        r"\b(can|could) you (send|share|paste|tell me) (me )?(the|a) (log|error|link|file|path|output)\b",
        r"\bdo you (have|know) (the|a|an)\b",
        r"\b(file|duong dan|phien ban|nhanh|link) (nao|gi)\b",
        r"\b(o dau|cho (toi|minh) xin (link|file|log))\b",
    ),
    Criterion.SAFE_DEFAULT: _compile(
        r"\b(should i|shall i|do you want me to|would you like me to|want me to) (go ahead|proceed|continue|start|begin|also|run|check|fix|update|add|create|try)\b",
        r"\bok(ay)? to (proceed|continue|go ahead)\b",
        r"\b(let me know (if|when) (you want|to proceed)|ready to proceed)\b",
        r"\b(co muon (toi|minh)|ban (co )?muon (toi|minh)|toi (co )?nen) (tiep tuc|lam|chay|kiem tra|sua|them|tao)\b",
    ),
    Criterion.REVERSIBLE: _compile(
        r"\b(rename|reformat|refactor|draft|preview|local|temporary|scratch|dry[- ]run|rerun|re-run|revert|undo)\b",
        r"\b(doi ten|ban nhap|ban xem truoc|chay lai)\b",
    ),
}

CORRECTION_PATTERNS: dict[str, tuple[re.Pattern, ...]] = {
    "ask_only_needed": _compile(
        r"\bonly ask (me )?(what|if|when|about)\b",
        r"\bask (only )?(what|when) (you|it) (really )?(need|is needed|is necessary)\b",
        r"\bchi hoi (nhung gi|khi|cai) can thiet\b",
        r"\bdung hoi (nhieu|thua|linh tinh|vo ich)\b",
    ),
    "do_not_reconfirm": _compile(
        r"\b(don'?t|do not|stop) (ask|confirm|re-?confirm)(ing)? (again|twice|every time)\b",
        r"\bno need to (re-?confirm|confirm|ask) (again|me)?\b",
        r"\bi (already|just) (said|told you|answered|confirmed)\b",
        r"\b(da|toi da|minh da) (noi|tra loi|xac nhan) (roi|ben tren)\b",
        r"\bdung (hoi|xac nhan) lai\b",
        r"\bkhong can (xac nhan|hoi lai)\b",
    ),
    "just_do_it": _compile(
        r"\bjust (do|make|run|send|fix|go) (it|that|ahead)\b",
        r"\bgo ahead (and|without)\b",
        r"\bstop asking\b",
        r"\b(cu lam|lam di|lam luon|lam luon di|cu tien hanh)\b",
        r"\bkhong can hoi\b",
    ),
    "decide_yourself": _compile(
        r"\b(you decide|your call|up to you|pick (one|whichever|whatever))\b",
        r"\b(tu quyet( dinh)?|tuy ban|ban tu chon|tu chon di)\b",
    ),
    "look_it_up": _compile(
        r"\b(check|look|find|figure) (it|that|this) (up|out) (yourself|on your own)\b",
        r"\bit'?s (already )?in the (file|repo|history|chat|memory|docs?)\b",
        r"\b(tu (tim|check|xem|kiem tra)( di| lai)?|xem (lai )?(lich su|file|trong (file|repo|chat)))\b",
    ),
    "be_proactive": _compile(
        r"\b(be )?(more )?proactive\b",
        r"\banticipate\b",
        r"\bdo it before i ask\b",
        r"\b(chu dong|lam truoc|doan truoc)\b",
    ),
    "too_many_options": _compile(
        r"\btoo many (options|questions|choices)\b",
        r"\bjust (give|tell) me (the|your) (best|recommend\w*|pick)\b",
        r"\b(nhieu (cau hoi|lua chon|phuong an) qua|chi (can )?(dua|cho) (ra )?(1|mot) (lua chon|phuong an))\b",
    ),
    "overreach_complaint": _compile(
        r"\bi (didn'?t|did not) (ask|tell) you to\b",
        r"\bwhy did you (send|delete|post|merge|publish|buy|pay)\b",
        r"\bdon'?t (send|delete|post|merge|publish|pay|buy)\b.*\bwithout\b",
        r"\b(sao (lai )?(gui|xoa|dang|merge)|chua cho phep|dung (gui|xoa|dang) khi chua)\b",
    ),
}


def question_text(text: str) -> str | None:
    body = (text or "").strip()
    if not body:
        return None
    lines = [line for line in body.splitlines() if line.strip()]
    last = _TRAILING_NOISE.sub("", lines[-1])
    if last.endswith("?"):
        return _last_paragraph(body)
    trailing = lines[-8:]
    option_rows = sum(1 for line in trailing if _OPTION_LINE.match(line))
    lead_has_question = any("?" in line for line in trailing if not _OPTION_LINE.match(line))
    if option_rows >= 2 and lead_has_question:
        return _last_paragraph(body)
    return None


def _last_paragraph(body: str) -> str:
    return body[-_LAST_PARAGRAPH_CHARS:]


def matched_criteria(text: str) -> frozenset[Criterion]:
    folded = fold(text)
    return frozenset(
        criterion for criterion, patterns in CRITERIA_PATTERNS.items()
        if any(pattern.search(folded) for pattern in patterns)
    )


def correction_classes(text: str) -> frozenset[str]:
    folded = fold(text)
    return frozenset(
        name for name, patterns in CORRECTION_PATTERNS.items()
        if any(pattern.search(folded) for pattern in patterns)
    )


BARE_YES_NO = frozenset({"yes", "no", "y", "n", "ok", "okay", "yep", "nope", "yeah", "co", "khong", "dong y",
                         "khong dong y", "dung", "sai"})
_DEFAULT_HINT = re.compile(
    r"\b(default|i'?ll assume|i will assume|assuming|i suggest|suggested|recommend(ed)?|mac dinh|de xuat|khuyen)\b")
_RECOMMEND_MARK = re.compile(r"\b(recommended|khuyen dung|de xuat)\b")
_HANDBACK = _compile(
    r"\b(please|you (can|could|should|need to|will need to|'ll need to)) (run|execute|paste|type) (the following|this|these|it)\b",
    r"\b(run|execute) (this|the following) (command|in your terminal)\b",
    r"\b(ban|anh|chi) (hay|can|phai) (chay|go|dan) (lenh|doan|cau)\b",
)


def option_labels(text: str) -> tuple[str, ...]:
    lines = [line for line in (text or "").splitlines() if line.strip()][-8:]
    rows = [re.sub(r"^\s*(?:[-*\u2022]|\d{1,2}[.)]|[A-Da-d][.)])\s+", "", line).strip() for line in lines if _OPTION_LINE.match(line)]
    return tuple(rows) if len(rows) >= 2 else ()


def question_count(text: str) -> int:
    body = _last_paragraph((text or "").strip())
    return max(1, sum(1 for line in body.splitlines() if _TRAILING_NOISE.sub("", line).endswith("?")))


def is_bare_yes_no(choices) -> bool:
    cleaned = [re.sub(r"[^\w ]", "", fold(c)).strip() for c in choices]
    return bool(cleaned) and all(c in BARE_YES_NO for c in cleaned)


def states_recommendation(text: str) -> bool:
    return bool(_RECOMMEND_MARK.search(fold(text)))


def states_default(text: str) -> bool:
    return bool(_DEFAULT_HINT.search(fold(text)))


def hands_back(text: str) -> bool:
    folded = fold(text)
    return any(pattern.search(folded) for pattern in _HANDBACK)


_CHASE = _compile(
    r"\b(any (update|news|progress)|what'?s the status|is it (done|ready|finished)|(done|ready|finished) yet)\b",
    r"\b(how'?s it going|where are we (on|with)|did you (finish|get to) (it|that|this)|how far along)\b",
    r"\b(xong chua|lam xong chua|the nao roi|sao roi|toi dau roi|den dau roi|co gi moi (chua|khong)|bao gio xong)\b",
    r"\bda (lam|gui|xong) chua\b",
)
_PROMISE = _compile(
    r"\bi('ll| will) (check back|follow up|get back to you|let you know|report back|ping you|keep an eye|monitor"
    r"|circle back|update you)\b",
    r"\b(toi|minh|em) se (bao lai|bao cho|kiem tra lai|cap nhat|theo doi|gui lai|quay lai|nhac)\b",
)


def is_chase(text: str) -> bool:
    folded = fold(text)
    return any(pattern.search(folded) for pattern in _CHASE)


def makes_promise(text: str) -> bool:
    folded = fold(text)
    return any(pattern.search(folded) for pattern in _PROMISE)
