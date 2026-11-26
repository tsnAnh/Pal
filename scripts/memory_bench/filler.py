from __future__ import annotations

import random
from dataclasses import dataclass

from scripts.memory_bench.model import Kind


@dataclass(frozen=True)
class Domain:
    projects: tuple[str, ...]
    objects_vi: tuple[str, ...]
    objects_en: tuple[str, ...]


@dataclass(frozen=True)
class Draft:
    said: str
    note: str
    topic: str
    kind: Kind = Kind.WORK


def _words(block: str) -> tuple[str, ...]:
    return tuple(part.strip() for part in block.split("|"))


DOMAINS: dict[str, Domain] = {
    "mobile": Domain(
        _words("Quillfish|app đặt phòng học|app Sao Biển"),
        _words(
            "màn hình đăng nhập|luồng đặt phòng|thông báo đẩy|bản dựng thử nghiệm|trang cài đặt|bộ nhớ đệm ảnh"
            "|mục lịch sử mượn|nút chia sẻ|chế độ ngoại tuyến|màn hình quét mã"
        ),
        _words(
            "onboarding flow|push notification handler|beta build|settings page|offline cache|booking calendar"
            "|crash report queue|deep link router|barcode screen|profile editor"
        ),
    ),
    "billing": Domain(
        _words("Tidemark|cổng hóa đơn Đồi Mật|Velmora portal"),
        _words(
            "mẫu hóa đơn|bảng công nợ|báo cáo thuế quý|luồng hoàn tiền|file đối soát|nhắc hạn thanh toán"
            "|trang bảng giá|phiếu thu điện tử|mã giảm giá|sổ quỹ"
        ),
        _words(
            "invoice template|reconciliation export|refund queue|tax summary|payment reminder|pricing table"
            "|credit note screen|currency rounding rule|ledger sync|dunning email"
        ),
    ),
    "design": Domain(
        _words("Mây Tre|trang Orrin Bakery|bộ nhận diện Hoa Gạo"),
        _words(
            "bảng màu|bộ biểu tượng|trang chủ|banner khuyến mãi|phông chữ tiêu đề|bản mẫu bao bì"
            "|trang giỏ hàng|ảnh chụp sản phẩm|logo phụ|thẻ sản phẩm"
        ),
        _words(
            "color tokens|icon set|landing hero|packaging mockup|type scale|checkout wireframe"
            "|photo moodboard|empty state art|menu poster|product card"
        ),
    ),
    "infra": Domain(
        _words("cụm staging|Lanternfly|máy chủ nội bộ"),
        _words(
            "bản sao lưu đêm|chứng chỉ bảo mật|ổ đĩa log|hàng đợi tác vụ|đường ống triển khai|bảng cảnh báo"
            "|cấu hình tường lửa|cơ sở dữ liệu thử|tên miền phụ|bộ cân bằng tải"
        ),
        _words(
            "nightly backup|deploy pipeline|alert dashboard|log retention job|database replica|build runner"
            "|firewall rule set|secrets rotation script|load balancer health check|cron host"
        ),
    ),
    "events": Domain(
        _words("hội chợ sách Hoa Gạo|ngày hội Đồi Mật|Harbor Meetup"),
        _words(
            "sơ đồ gian hàng|danh sách khách mời|tờ rơi|suất ăn trưa|hợp đồng thuê âm thanh|bảng chỉ dẫn"
            "|đội tình nguyện|quà lưu niệm|lịch diễn giả|bàn đón tiếp"
        ),
        _words(
            "booth map|speaker lineup|catering order|badge printing|venue deposit|volunteer rota"
            "|sponsor deck|signage kit|livestream rig|swag boxes"
        ),
    ),
    "clinic": Domain(
        _words("Phòng khám Sen Cạn|cổng đặt hẹn Sen Cạn|Sen Cạn kiosk"),
        _words(
            "lịch trực lễ tân|mẫu tin nhắn nhắc hẹn|màn hình xếp hàng|biểu mẫu đăng ký|máy in số thứ tự"
            "|bảng giá dịch vụ|danh mục bác sĩ|trang đặt lịch|hướng dẫn sử dụng quầy|báo cáo lượt khám"
        ),
        _words(
            "queue display|intake form|reminder text template|ticket printer driver|doctor roster page"
            "|visit report|kiosk idle screen|slot booking rule|consent checkbox|reception tablet"
        ),
    ),
    "warehouse": Domain(
        _words("Brindle|kho Velmora|máy quét Đồi Mật"),
        _words(
            "tem mã vạch|phiếu nhập kho|sơ đồ kệ|máy quét cầm tay|danh sách hàng lỗi|đợt kiểm kê"
            "|xe nâng thuê|phần mềm đóng gói|khu hàng trả|bảng ca bốc xếp"
        ),
        _words(
            "pallet labels|picking route|handheld firmware|returns shelf|cycle count sheet|dock schedule"
            "|packing station app|stock mismatch report|freight manifest|scanner cradle"
        ),
    ),
    "team": Domain(
        _words("nhóm sản phẩm|văn phòng tầng ba|the studio"),
        _words(
            "lịch phỏng vấn|sổ tay nhân viên mới|ngân sách đào tạo|lịch nghỉ phép|buổi tổng kết tuần"
            "|máy chiếu phòng họp|bàn làm việc mới|danh sách thiết bị|lịch dọn kho tài liệu|khảo sát nội bộ"
        ),
        _words(
            "interview loop|onboarding checklist|training budget|leave calendar|weekly demo agenda"
            "|meeting room booking|laptop inventory|pairing roster|retro board|referral list"
        ),
    ),
}

STATES_VI = _words(
    "đang chậm tiến độ|đã chạy ổn trở lại|cần người rà lại|bị lỗi hiển thị|đã xong bản nháp|chờ khách phản hồi"
    "|vẫn thiếu dữ liệu mẫu|được duyệt sơ bộ|phải làm lại một phần|đã chuyển sang bước kiểm thử"
)
STATES_EN = _words(
    "is running behind|is stable again|needs a second reviewer|shows a layout glitch|has a first draft ready"
    "|is waiting on client feedback|is still missing sample data|passed an informal review|needs partial rework"
    "|moved into testing"
)
DONE_VI = _words(
    "rà soát|cập nhật|dọn lại|gửi bản mới của|thử nghiệm|sửa lỗi cho|ghi chép lại|đóng phiếu cũ của|đo thời gian xử lý của"
    "|bàn giao"
)
DONE_EN = _words(
    "reviewed|refreshed|cleaned up|sent a new version of|smoke-tested|patched|wrote notes on|closed old tickets for"
    "|timed|handed over"
)
TASK_VI = _words(
    "nhận phần|kiểm tra giúp|viết hướng dẫn cho|ước lượng công cho|chụp màn hình|dịch nội dung của|sắp lịch cho"
    "|gom phản hồi về"
)
TASK_EN = _words(
    "take over|double-check|document|estimate the effort for|collect screenshots of|translate the copy in"
    "|schedule time for|gather feedback on"
)
CHANGE_VI = _words(
    "tách nhỏ|đơn giản hóa|làm lại giao diện của|tạm ẩn|gộp chung|tự động hóa|đổi tên|bổ sung số liệu cho"
)
CHANGE_EN = _words("split up|simplify|redesign|temporarily hide|merge|automate|rename|add metrics to")
REASONS_VI = _words(
    "khách mới đổi yêu cầu|số liệu tuần này lệch|có hai người đang nghỉ|bản cũ khó bảo trì|người dùng thử phàn nàn"
    "|đối tác gửi tài liệu muộn|mạng văn phòng chập chờn|phần kiểm thử còn dở|ngân sách đợt này hẹp|trùng với đợt bàn giao"
)
REASONS_EN = _words(
    "the client changed the brief|this week's numbers look off|two people are out|the old version is hard to maintain"
    "|testers complained about it|the partner sent files late|the office network kept dropping|test coverage is thin"
    "|the budget is tight this round|it overlaps with the handover"
)
AFTER_VI = _words(
    "dự kiến mất thêm hai ngày|sẽ xem lại vào đầu tuần sau|chưa cần làm gấp|đã báo cho cả nhóm"
    "|ai rảnh thì nhận giúp|đang đợi thêm một vòng góp ý"
)
AFTER_EN = _words(
    "expects it to take two more days|will revisit early next week|does not consider it urgent|told the rest of the group"
    "|is open to someone else picking it up|is waiting for one more round of comments"
)

DETAIL_VI = _words(
    "Phiếu việc đã đính kèm ảnh chụp và các bước tái hiện để người nhận không phải hỏi lại"
    "|Phần còn lại phụ thuộc vào vòng góp ý của khách, nên chưa chốt mốc mới"
    "|Bản cũ được giữ nguyên thêm một tuần phòng khi cần quay lại nhanh"
    "|Cả nhóm sẽ nhìn lại số liệu trong buổi họp ngắn đầu tuần rồi mới làm tiếp"
    "|Mọi thay đổi đều ghi vào bảng theo dõi chung để bộ phận hỗ trợ nắm được"
)
DETAIL_EN = _words(
    "The ticket now has screenshots and reproduction steps so whoever picks it up does not need to ask again"
    "|The remaining part depends on another round of client comments, so no new date has been set"
    "|The old version stays in place for one more week in case a quick rollback is needed"
    "|The group will look at the numbers in the short Monday sync before doing anything further"
    "|Every change is being logged on the shared tracker so the support side can follow along"
)

DETAIL_SHARE = 0.55
VIETNAMESE_CHAR_LIMIT = 205
ENGLISH_CHAR_LIMIT = 470

CHATTER_VI = _words(
    "máy pha cà phê ở bếp lại kêu to|trà đá hết từ đầu giờ chiều|điều hòa phòng họp lạnh quá mức|có người để quên ô ở cửa"
    "|quán bún đầu ngõ nghỉ bán|chậu trầu bà cạnh cửa sổ sắp héo|thang máy dừng ở tầng hai khá lâu"
    "|tủ lạnh còn một hộp xôi không ai nhận|trời mưa to nên gửi xe hơi khó|tai nghe dùng chung bị rè một bên"
    "|bánh sinh nhật còn thừa trên bàn|wifi khách đổi tên nghe rất buồn cười"
)
CHATTER_EN = _words(
    "the espresso machine is leaking again|the pantry ran out of oat milk|the meeting room chair squeaks"
    "|someone left an umbrella by the door|the noodle place downstairs was packed|the window plant looks thirsty"
    "|the lift stalled for a moment|a mystery lunchbox is still in the fridge|the parking ramp flooded a bit"
    "|the shared headphones crackle on one side|there is leftover cake on the long table|the guest wifi got a silly name"
)
CHATTER_TAIL_VI = _words("|, cả nhóm cười một lúc|, chắc mai lại thế|, không ảnh hưởng công việc|, ai đi ngang cũng nhắc")
CHATTER_TAIL_EN = _words(", just so people know|, and everyone laughed|, probably again tomorrow|, nothing work related|, people kept mentioning it")

SMALL_TALK_VI = _words(
    "ok để mình xem nhé|chờ mình năm phút|mình đồng ý|cảm ơn mọi người|đang họp, lát trả lời|có ai ăn trưa chưa"
    "|nghe hợp lý đó|mình vừa đọc xong|để chiều tính tiếp|haha chuẩn luôn|gửi lại link giúp mình với|mai mình tới trễ chút"
)
SMALL_TALK_EN = _words(
    "ok let me look|give me five minutes|sounds good to me|thanks all|in a call, will reply later|anyone up for lunch"
    "|that makes sense|just finished reading|let's pick this up this afternoon|haha exactly|can you resend that please"
    "|running a bit late tomorrow"
)
SMALL_TALK_ENDS = _words("| nha| nhé {who}| @{who}| 👍| ạ| :)")


def small_talk(rng: random.Random, who: str) -> str:
    pool = SMALL_TALK_VI if rng.random() < 0.5 else SMALL_TALK_EN
    return rng.choice(pool) + rng.choice(SMALL_TALK_ENDS).format(who=who)


def _slug(*parts: str) -> str:
    return "-".join("-".join(part.lower().split()) for part in parts if part)


def _tail_vi(rng: random.Random) -> str:
    roll = rng.random()
    if roll < 0.35:
        return ""
    if roll < 0.75:
        return f" vì {rng.choice(REASONS_VI)}"
    return f" vì {rng.choice(REASONS_VI)}; {rng.choice(AFTER_VI)}"


def _tail_en(rng: random.Random, who: str) -> str:
    roll = rng.random()
    if roll < 0.35:
        return ""
    if roll < 0.75:
        return f" because {rng.choice(REASONS_EN)}"
    return f" because {rng.choice(REASONS_EN)}; {who} {rng.choice(AFTER_EN)}"


def _detailed(rng: random.Random, note: str, pool: tuple[str, ...], limit: int) -> str:
    if rng.random() >= DETAIL_SHARE:
        return note
    longer = f"{note} {rng.choice(pool)}."
    return longer if len(longer) <= limit else note


def _work_vi(rng: random.Random, who: str, date: str, project: str, thing: str) -> tuple[str, str]:
    tail = _tail_vi(rng)
    state, done = rng.choice(STATES_VI), rng.choice(DONE_VI)
    task, change = rng.choice(TASK_VI), rng.choice(CHANGE_VI)
    return rng.choice(
        (
            (f"{thing} bên {project} {state} nha", f"{who} báo ngày {date} rằng {thing} của {project} {state}{tail}."),
            (f"mình mới {done} {thing} cho {project}", f"Ngày {date}, {who} đã {done} {thing} của {project}{tail}."),
            (f"ai {task} {thing} bên {project} được không?", f"{who} hỏi hôm {date} ai có thể {task} {thing} cho {project}{tail}."),
            (f"hay mình {change} {thing} của {project} đi", f"{who} đề xuất ngày {date} nên {change} {thing} của {project}{tail}."),
        )
    )


def _work_en(rng: random.Random, who: str, date: str, project: str, thing: str) -> tuple[str, str]:
    tail = _tail_en(rng, who)
    state, done = rng.choice(STATES_EN), rng.choice(DONE_EN)
    task, change = rng.choice(TASK_EN), rng.choice(CHANGE_EN)
    return rng.choice(
        (
            (f"heads up, {project} {thing} {state}", f"{who} reported on {date} that the {thing} for {project} {state}{tail}."),
            (f"I {done} the {thing} for {project}", f"On {date}, {who} {done} the {thing} for {project}{tail}."),
            (f"can someone {task} the {project} {thing}?", f"{who} asked on {date} for someone to {task} the {thing} for {project}{tail}."),
            (f"maybe we {change} the {thing} on {project}", f"{who} suggested on {date} that the team {change} the {thing} for {project}{tail}."),
        )
    )


def work(rng: random.Random, domain: str, who: str, date: str) -> Draft:
    area = DOMAINS[domain]
    project = rng.choice(area.projects)
    if rng.random() < 0.5:
        thing = rng.choice(area.objects_vi)
        said, note = _work_vi(rng, who, date, project, thing)
        note = _detailed(rng, note, DETAIL_VI, VIETNAMESE_CHAR_LIMIT)
    else:
        thing = rng.choice(area.objects_en)
        said, note = _work_en(rng, who, date, project, thing)
        note = _detailed(rng, note, DETAIL_EN, ENGLISH_CHAR_LIMIT)
    topic = rng.choice((_slug(project, thing), _slug(thing), _slug(project, thing, "status")))
    return Draft(said, note, topic)


def chatter(rng: random.Random, who: str, date: str) -> Draft:
    if rng.random() < 0.5:
        what = rng.choice(CHATTER_VI)
        note = f"{who} kể hôm {date} rằng {what}{rng.choice(CHATTER_TAIL_VI)}."
        said = f"trời ơi {what}"
    else:
        what = rng.choice(CHATTER_EN)
        note = f"{who} mentioned on {date} that {what}{rng.choice(CHATTER_TAIL_EN)}."
        said = f"lol {what}"
    topic = rng.choice(("office-chatter", "pantry", "random", _slug(who, "moment")))
    kind = Kind.MOMENT if rng.random() < 0.12 else Kind.WORK
    return Draft(said, note, topic, kind)


class Writer:
    def __init__(self, rng: random.Random) -> None:
        self.rng = rng
        self.seen: set[str] = set()

    def work(self, domain: str, who: str, date: str) -> Draft:
        return self._fresh(lambda: work(self.rng, domain, who, date))

    def chatter(self, who: str, date: str) -> Draft:
        return self._fresh(lambda: chatter(self.rng, who, date))

    def _fresh(self, make) -> Draft:
        for _ in range(200):
            draft = make()
            if draft.note not in self.seen:
                self.seen.add(draft.note)
                return draft
        raise RuntimeError("filler vocabulary exhausted")


def date_label(day: int) -> str:
    if day < 30:
        return f"{day + 2}/3"
    return f"{day - 29}/4"


CONTEXT_VI = _words(
    "Mọi người đã trao đổi khá kỹ trước khi ghi lại ý này, và sẽ xem lại nếu phía khách đổi yêu cầu."
    "|Phần này liên quan đến vài việc đang làm song song nên cần để ý thứ tự khi bắt tay vào."
    "|Lý do chính là tránh phải làm lại từ đầu, đồng thời giữ cho cả nhóm cùng hiểu một cách."
    "|Chi tiết cụ thể sẽ được bổ sung trong buổi trao đổi tiếp theo khi mọi người có đủ thông tin."
    "|Nếu có gì chưa rõ thì hỏi thẳng người nêu ra, đừng tự suy đoán rồi làm khác đi."
    "|Việc này không gấp lắm nhưng để lâu quá thì dễ bị quên giữa nhiều đầu việc khác."
)
CONTEXT_EN = _words(
    "The group talked it through before writing this down and will revisit it if the client changes course."
    "|It touches a few pieces of work running in parallel, so the order of the steps matters here."
    "|The main reason is to avoid redoing the same effort and to keep everyone on one understanding."
    "|Finer details are expected at the next catch-up, once the people involved have what they need."
    "|Anyone unsure should ask the person who raised it instead of guessing and doing something else."
    "|It is not urgent, yet leaving it too long makes it easy to lose among other open work."
)


def context(rng: random.Random, in_vietnamese: bool, sentences: int) -> list[str]:
    return rng.sample(CONTEXT_VI if in_vietnamese else CONTEXT_EN, sentences)

