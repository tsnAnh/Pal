from __future__ import annotations

import random
from dataclasses import dataclass, replace

from scripts.memory_bench.filler import DOMAINS, Draft, Writer, context, date_label, small_talk
from scripts.memory_bench.model import (
    Forbidden,
    ForbiddenReason,
    History,
    Item,
    ItemKind,
    Kind,
    Load,
    Place,
    Probe,
    Proposal,
    Question,
    SalienceMode,
    Source,
    Turn,
    vietnamese,
)

OWNER = "Vy"
LAST_DAY = 30
QUESTION_START = LAST_DAY + 1.0
QUESTION_STEP = 0.001


@dataclass(frozen=True)
class Volume:
    proposals: tuple[int, int]
    context_sentences: int


VOLUMES: dict[Load, Volume] = {Load.TYPICAL: Volume((29, 31), 0), Load.AT_CAP: Volume((58, 62), 3)}


@dataclass(frozen=True)
class Channel:
    source: Source
    name: str
    domains: tuple[str, ...]
    members: tuple[str, ...]
    weight: int


CHANNELS: dict[str, Channel] = {
    "pal": Channel(Source.PAL_APP, "pal-chat", tuple(DOMAINS), (OWNER,), 8),
    "qf": Channel(Source.SLACK, "quillfish-app", ("mobile",), ("Quân", "Thảo", "Priya", "Bảo", OWNER), 7),
    "td": Channel(Source.SLACK, "tidemark-billing", ("billing",), ("Hạnh", "Marek", "Khoa", OWNER), 7),
    "ds": Channel(Source.SLACK, "studio-design", ("design",), ("Lan Anh", "Noor", "Thảo", OWNER), 6),
    "inf": Channel(Source.SLACK, "infra-ops", ("infra",), ("Bảo", "Tomas", "Dung", OWNER), 6),
    "ev": Channel(Source.SLACK, "events-desk", ("events", "team"), ("Dung", "Noor", "Hạnh", OWNER), 6),
}


@dataclass(frozen=True)
class Fact:
    key: str
    day: int
    said: str
    note: str
    topic: str


@dataclass(frozen=True)
class Old:
    fact: Fact
    markers: tuple[str, ...]


@dataclass(frozen=True)
class Need:
    fact: Fact
    kind: ItemKind
    home: str
    speaker: str
    markers: tuple[str, ...]
    ask_home: str
    asker: str
    ask: str
    old: Old | None = None
    again: tuple[Fact, ...] = ()


@dataclass(frozen=True)
class Planned:
    key: str
    kind: Kind
    text: str
    topic: str
    needed: bool


@dataclass(frozen=True)
class Slot:
    at: float
    place: Place
    speaker: str
    said: str
    notes: tuple[Planned, ...] = ()


def need(
    key: str,
    kind: ItemKind,
    day: int,
    home: str,
    speaker: str,
    said: str,
    note: str,
    topic: str,
    markers: tuple[str, ...],
    asked: tuple[str, str, str],
    old: tuple[int, str, str, str, tuple[str, ...]] | None = None,
    again: tuple[int, str, str] | None = None,
) -> Need:
    previous = None
    if old is not None:
        old_day, old_said, old_note, old_topic, old_markers = old
        previous = Old(Fact(f"{key}-old", old_day, old_said, old_note, old_topic), old_markers)
    repeats = () if again is None else (Fact(key, again[0], again[1], again[2], topic),)
    return Need(Fact(key, day, said, note, topic), kind, home, speaker, markers, *asked, previous, repeats)


F = ItemKind.FACT
D = ItemKind.DECISION
C = ItemKind.COMMITMENT
P = ItemKind.PREFERENCE

EARLY: tuple[Need, ...] = (
    need("h01", D, 1, "pal", OWNER, "chốt nhé: đợt phát hành lớn tới của Quillfish gọi là Cá Chuồn, tên cũ trùng tính năng",
         "{d}: Vy chốt dùng tên mã Cá Chuồn cho đợt phát hành lớn tiếp theo của Quillfish, vì tên cũ trùng với một tính năng đang chạy.",
         "quillfish-release-codename", ("Cá Chuồn",), ("qf", OWNER, "tên mã đợt phát hành lớn kế tiếp của app là gì nhỉ?"),
         again=(6, "nhắc lại cho khỏi nhầm: đợt tới là Cá Chuồn", "Vy nhắc lại ngày {d} rằng tên mã của đợt phát hành Quillfish sắp tới là Cá Chuồn.")),
    need("h02", P, 2, "pal", OWNER, "from now on keep my meeting recaps to five bullets max, decision on line one",
         "On {d}, Vy said meeting summaries written for Vy must be at most five bullets, with the decision on the first line.",
         "vy-summary-format", ("five bullets",), ("pal", OWNER, "Tóm tắt buổi họp sáng nay giúp mình theo đúng kiểu mình thích nhé")),
    need("h03", F, 2, "qf", "Priya", "fyi the booking API bounces anything older than 90 seconds, clock-skew guard",
         "Priya noted on {d} that the Quillfish booking API rejects requests older than 90 seconds because of clock-skew protection, so phones with a drifting clock see a generic booking failure.",
         "booking-api-clock-skew", ("90 seconds",), ("qf", "Quân", "Why would a booking bounce when the phone clock is off?")),
    need("h04", C, 3, "td", "Hạnh", "em sẽ gửi bảng đối soát quý một cho kế toán Đồi Mật trước thứ Sáu 20/3",
         "Hạnh hứa ngày {d} sẽ gửi bảng đối soát quý một cho kế toán Đồi Mật trước thứ Sáu 20/3.",
         "doi-mat-q1-reconciliation", ("đối soát quý một", "20/3"), ("td", "Marek", "Bảng quý một bên Đồi Mật hạn gửi là khi nào vậy?"),
         again=(9, "vẫn giữ hạn 20/3 cho bảng đối soát quý một nha", "Hạnh xác nhận lại ngày {d}: bảng đối soát quý một gửi kế toán Đồi Mật vẫn giữ hạn 20/3.")),
    need("h05", P, 4, "ds", "Lan Anh", "please always check Orrin print proofs on uncoated stock before sign-off",
         "Lan Anh said on {d} that print proofs for Orrin Bakery must be checked on uncoated paper before anyone signs off.",
         "orrin-print-proofing", ("uncoated",), ("ds", OWNER, "Trước khi duyệt bản in cho tiệm bánh Orrin thì Lan Anh yêu cầu gì?")),
    need("h06", F, 4, "inf", "Bảo", "con server Gấu Trúc giữ backup 21 ngày rồi tự xóa đó mọi người",
         "Bảo ghi nhận ngày {d}: máy chủ nội bộ tên Gấu Trúc giữ bản sao lưu trong 21 ngày rồi tự xóa.",
         "backup-retention", ("Gấu Trúc",), ("inf", "Tomas", "How long does the internal backup box keep copies before wiping them?")),
    need("h07", C, 5, "ev", "Dung", "I'll lock the tent rental with Mái Lá for the book fair by 18/3",
         "Dung promised on {d} to confirm the Hoa Gạo book fair tent rental with the vendor Mái Lá by 18/3.",
         "fair-tent-rental", ("Mái Lá",), ("ev", "Noor", "Ai đang lo chốt thuê lều cho hội chợ sách thế?")),
    need("h08", F, 5, "pal", OWNER, "ghi giúp: hợp đồng bảo trì Velmora 186 triệu, gia hạn tháng sáu",
         "{d}, Vy ghi lại: hợp đồng bảo trì với Velmora Freight trị giá 186 triệu đồng và đến kỳ gia hạn vào tháng sáu.",
         "velmora-maintenance-contract", ("186 triệu",), ("td", OWNER, "Velmora trả bao nhiêu cho gói bảo trì nhỉ?")),
    need("h09", D, 6, "td", "Marek", "decided: VAT gets rounded per invoice line, not on the total, Velmora audit wants that",
         "On {d}, Marek decided Tidemark will round VAT per invoice line instead of per invoice total, to match Velmora's audit rules; per-total rounding had produced differences of a few dong that their auditor refused to accept.",
         "tidemark-vat-rounding", ("per invoice line",), ("td", "Hạnh", "VAT trên Tidemark làm tròn theo từng dòng hay theo tổng hóa đơn?"),
         again=(13, "reminder, VAT rounding stays per invoice line", "Marek reminded the billing channel on {d} that VAT rounding stays per invoice line.")),
    need("h10", P, 6, "qf", "Quân", "mọi PR của Quillfish kèm video quay màn hình rồi hãy xin review nha",
         "Quân nói ngày {d} rằng mọi pull request của app Quillfish phải kèm video quay màn hình trước khi xin duyệt.",
         "quillfish-pr-evidence", ("video quay màn hình",), ("qf", "Priya", "Do I need to attach anything to an app PR before asking for review?")),
    need("h11", C, 7, "pal", OWNER, "I owe Mrs Ardent the half-year investor letter by 27/3",
         "On {d}, Vy committed to sending the half-year investor letter to Mrs Ardent by 27/3.",
         "investor-letter", ("Ardent",), ("td", OWNER, "when is the letter to our investor due again?")),
    need("h12", D, 7, "inf", "Tomas", "moving staging cron over to the Basalt host, the old box cooks itself at night",
         "Tomas decided on {d} to move the staging cluster's cron jobs to the Basalt host, since the old box overheats at night and two scheduled runs were silently skipped last week.",
         "staging-cron-host", ("Basalt",), ("inf", "Dung", "Mấy cron job của staging giờ chạy trên máy nào?")),
    need("h13", F, 8, "ds", "Noor", "xanh chủ đạo mới của Hoa Gạo là #2F6B4F nhé",
         "Noor cho biết ngày {d} màu xanh chủ đạo mới trong bộ nhận diện Hoa Gạo là mã #2F6B4F.",
         "hoa-gao-brand-color", ("#2F6B4F",), ("ds", "Lan Anh", "What's the hex code for the new library green?")),
    need("h14", P, 8, "ev", "Hạnh", "for Harbor Meetup catering please always include a labelled peanut-free tray",
         "Hạnh asked on {d} that every Harbor Meetup catering order include a clearly labelled peanut-free tray.",
         "meetup-catering-rule", ("peanut-free",), ("ev", "Dung", "Đặt đồ ăn cho buổi meetup thì Hạnh dặn gì ấy nhỉ?")),
    need("h15", P, 9, "pal", OWNER, "đừng xếp họp trước 9 giờ 30 sáng thứ Hai nhé, giờ đó mình dọn hộp thư",
         "Ngày {d}, Vy dặn đừng đặt lịch họp trước 9 giờ 30 sáng thứ Hai vì đó là giờ Vy dọn hộp thư.",
         "vy-monday-mornings", ("9 giờ 30",), ("ev", "Dung", "Xếp họp sáng thứ Hai với Vy thì sớm nhất được mấy giờ?"),
         again=(21, "nhắc lại: thứ Hai trước 9 giờ 30 là mình không họp", "Vy nhắc lại ngày {d} rằng Vy không họp trước 9 giờ 30 sáng thứ Hai.")),
    need("h16", F, 9, "qf", "Bảo", "those Android 9 tablet crashes are the old Compass2 map widget",
         "Bảo reported on {d} that Quillfish crashes on Android 9 tablets come from the legacy map widget named Compass2.",
         "android9-tablet-crash", ("Compass2",), ("qf", "Quân", "Cái gì làm app sập trên máy tính bảng Android 9 vậy?")),
    need("h17", C, 10, "td", "Khoa", "em nhận viết lại luồng hoàn tiền, demo vào buổi sáng 31/3",
         "Khoa nhận ngày {d} sẽ viết lại luồng hoàn tiền của Tidemark và demo vào buổi sáng 31/3.",
         "refund-flow-rewrite", ("demo vào buổi sáng", "31/3"), ("td", "Marek", "When is Khoa showing the rewritten refunds?")),
    need("h18", D, 10, "pal", OWNER, "decision: we take no new clinic projects until the Sen Cạn portal ships",
         "On {d}, Vy decided the studio will not take new clinic projects until the Sen Cạn portal ships, to protect the team's capacity, because the same two people would otherwise cover both projects through the whole spring.",
         "clinic-project-freeze", ("new clinic projects",), ("ds", OWNER, "Lúc này mình có nên nhận thêm dự án phòng khám không?")),
    need("h19", F, 11, "inf", "Dung", "cert của tên miền phụ kiosk hết hạn 29/4 nhé",
         "Dung ghi ngày {d} rằng chứng chỉ bảo mật của tên miền phụ kiosk hết hạn vào ngày 29/4.",
         "kiosk-certificate", ("29/4",), ("inf", "Bảo", "When does the cert on the kiosk subdomain run out?")),
    need("h20", C, 11, "ds", "Thảo", "I'll get Orrin three kraft paper packaging mockups by 24/3",
         "Thảo promised on {d} to hand Orrin Bakery three packaging mockups on kraft paper by 24/3.",
         "orrin-packaging-mockups", ("kraft",), ("ds", OWNER, "Mấy mẫu bao bì cho tiệm bánh bao giờ có?")),
    need("h21", D, 12, "ev", OWNER, "chuyển bàn đón tiếp sang cổng Đông, cổng chính đang sửa vỉa hè",
         "Vy chốt ngày {d} chuyển bàn đón tiếp của hội chợ sách sang cổng Đông vì cổng chính đang sửa vỉa hè và xe chở sách không thể dừng ở đó trong suốt tuần hội chợ.",
         "fair-welcome-desk", ("cổng Đông",), ("ev", "Noor", "Where is the welcome table going to be at the fair?")),
    need("h22", F, 13, "pal", OWNER, "note: the office lease renewal needs the landlord signing form LH-72 before end of April",
         "Vy noted on {d} that the office lease renewal needs the landlord's signature on form LH-72 before the end of April.",
         "office-lease-renewal", ("LH-72",), ("pal", OWNER, "Gia hạn thuê văn phòng thì chủ nhà phải ký mẫu nào?")),
    need("h23", F, 14, "qf", "Thảo", "bản beta chỉ mời được tối đa 150 người dùng bên thư viện thôi",
         "Thảo cho biết ngày {d}: bản dựng thử nghiệm Quillfish chỉ mời được tối đa 150 người dùng của thư viện Hoa Gạo.",
         "beta-invite-limit", ("150 người dùng",), ("qf", "Priya", "What's the ceiling on library testers for the beta?")),
    need("h24", P, 15, "td", "Hạnh", "accountant exports must be semicolon separated please",
         "Hạnh said on {d} that Tidemark exports for accountants must use the semicolon as the column separator.",
         "accountant-export-format", ("semicolon",), ("td", "Khoa", "File xuất cho kế toán dùng dấu gì để ngăn cột nhỉ?")),
)

MIDDLE: tuple[Need, ...] = (
    need("h25", D, 16, "pal", OWNER, "dời ngày ra mắt công khai Quillfish sang 12/5, thủ thư cần thêm thời gian tập huấn",
         "Ngày {d}, Vy dời ngày ra mắt công khai Quillfish sang 12/5, vì thư viện cần thêm thời gian tập huấn thủ thư và chưa xong phần hướng dẫn tại quầy.",
         "quillfish-launch-date", ("12/5",), ("qf", "Quân", "Giờ mình ra mắt Quillfish cho công chúng ngày nào?"),
         old=(4, "public launch for Quillfish: first week of May", "On {d}, Vy set the Quillfish public launch for the first week of May.", "quillfish-launch-date", ("first week of May",)),
         again=(24, "launch vẫn là 12/5 nha mọi người", "Vy xác nhận ngày {d} rằng Quillfish vẫn ra mắt công khai vào 12/5.")),
    need("h26", C, 16, "qf", "Priya", "I'm taking the double-booking race, fixed before the April pilot",
         "Priya committed on {d} to fixing the double-booking race in room reservations before the April pilot.",
         "double-booking-fix", ("double-booking race",), ("qf", OWNER, "Vụ hai người đặt trùng một phòng thì ai đang sửa?")),
    need("h27", F, 16, "td", "Marek", "cổng Sò Điệp ngâm tiền hoàn 5 ngày làm việc đấy",
         "Marek báo ngày {d} rằng cổng thanh toán Sò Điệp giữ tiền hoàn trong 5 ngày làm việc.",
         "refund-gateway-delay", ("Sò Điệp",), ("td", "Hạnh", "How long does the payment gateway sit on refunds?")),
    need("h28", C, 17, "pal", OWNER, "promised Mr Fennick at Velmora a revised support quote by 3/4",
         "On {d}, Vy promised Mr Fennick of Velmora a revised support quote by 3/4.",
         "velmora-support-quote", ("Fennick",), ("td", OWNER, "Bao giờ mình phải gửi báo giá hỗ trợ bản sửa cho Velmora?"),
         again=(22, "still on the hook for Fennick's quote, 3/4", "Vy repeated on {d} that the revised quote for Mr Fennick is still due 3/4.")),
    need("h29", D, 17, "ds", "Lan Anh", "swapping the Mây Tre headline face to Bricolage Linden, the old one mangles stacked accents",
         "On {d}, Lan Anh replaced the Mây Tre headline typeface with Bricolage Linden because the earlier one broke Vietnamese stacked accents on small screens and the shop owner noticed it in a product title.",
         "type-choice-update", ("Bricolage Linden",), ("ds", "Noor", "Which headline font are we using for the craft shop now?"),
         old=(6, "tiêu đề trang Mây Tre dùng phông Phù Sa nhé", "Lan Anh chốt ngày {d} dùng phông Phù Sa cho tiêu đề của trang Mây Tre.", "may-tre-heading-font", ("Phù Sa",))),
    need("h30", P, 17, "inf", "Tomas", "nhờ mọi người đừng deploy lên staging sau 4 giờ chiều thứ Sáu",
         "Tomas yêu cầu ngày {d}: không ai triển khai lên cụm staging sau 4 giờ chiều thứ Sáu.",
         "friday-deploy-rule", ("sau 4 giờ chiều thứ Sáu",), ("inf", "Dung", "Can I push to staging late on a Friday?")),
    need("h31", F, 18, "ev", "Dung", "confirmed, Lighthouse Hall seats 220 for the meetup",
         "Dung confirmed on {d} that the Harbor Meetup venue, Lighthouse Hall, seats 220 people.",
         "event-venue", ("Lighthouse Hall",), ("ev", "Noor", "Hội trường cho buổi meetup chứa được bao nhiêu người?")),
    need("h32", P, 18, "pal", OWNER, "báo giá gửi khách ghi tiền Việt kèm tỷ giá ngày, đừng ghi đô trơn",
         "{d}, Vy dặn mọi báo giá gửi khách phải ghi bằng đồng Việt Nam kèm tỷ giá ngày, không ghi đô la trơn.",
         "quote-currency-format", ("tỷ giá ngày",), ("td", OWNER, "Draft the quote for the new client, in the money format I want")),
    need("h33", D, 18, "qf", "Quân", "dropping QR check-in, we go with a four-digit room code",
         "Quân decided on {d} to drop QR-code check-in from Quillfish and use a four-digit room code instead.",
         "room-checkin-method", ("four-digit room code",), ("qf", "Bảo", "Nhận phòng giờ làm bằng cách nào, còn quét QR không?")),
    need("h34", F, 19, "td", "Khoa", "tìm ra rồi: lệch công nợ do hóa đơn TM-5518 bị nhập hai lần",
         "Khoa phát hiện ngày {d} rằng lỗi lệch công nợ đến từ hóa đơn mã TM-5518 bị nhập hai lần.",
         "receivables-mismatch", ("TM-5518",), ("td", OWNER, "What caused the gap in the receivables numbers?")),
    need("h35", F, 19, "pal", OWNER, "set the cloud bill alert at 38 million dong a month",
         "On {d}, Vy noted that the studio's cloud bill alert threshold is set to 38 million dong per month.",
         "cloud-spend-alert", ("38 million",), ("inf", OWNER, "Ngưỡng cảnh báo tiền cloud hàng tháng đang để bao nhiêu?")),
    need("h36", C, 19, "ds", "Noor", "mình nhận vẽ 24 biểu tượng cho app Sao Biển, xong trước 4/4",
         "Noor nhận ngày {d} sẽ vẽ xong bộ 24 biểu tượng cho app Sao Biển trước 4/4.",
         "sao-bien-icons", ("24 biểu tượng",), ("ds", "Thảo", "Who has the Sao Biển icons and by when?")),
    need("h37", D, 20, "inf", "Bảo", "dời backup đêm sang 03:40 nhé, tránh đụng đợt xuất báo cáo",
         "Ngày {d}, Bảo dời giờ sao lưu cơ sở dữ liệu hàng đêm sang 03:40 để tránh đụng đợt xuất báo cáo, vốn đã hai lần khóa bảng và làm bản sao lưu bị dở dang.",
         "backup-window", ("03:40",), ("inf", "Tomas", "What time does the nightly database dump kick off these days?"),
         old=(7, "nightly db backup goes at 01:15", "On {d}, Bảo scheduled the nightly database backup for 01:15.", "backup-window", ("01:15",))),
    need("h38", C, 20, "ev", "Hạnh", "I'll wire Âm Vang the 12 million sound deposit by 28/3",
         "Hạnh promised on {d} to wire the 12 million dong sound system deposit for the book fair to Âm Vang by 28/3.",
         "fair-sound-deposit", ("Âm Vang",), ("ev", "Dung", "Tiền cọc dàn âm thanh hẹn chuyển khi nào ấy?"),
         again=(24, "Âm Vang deposit still goes out by 28/3", "Hạnh restated on {d} that the Âm Vang deposit goes out by 28/3.")),
    need("h39", P, 20, "qf", "Priya", "tag me only in the release-train thread please, no DMs about releases",
         "Priya asked on {d} to be tagged about releases only in the thread titled release-train, never in direct messages.",
         "priya-release-pings", ("release-train",), ("qf", "Quân", "Muốn hỏi Priya chuyện phát hành thì tag ở đâu?")),
    need("h40", D, 20, "pal", OWNER, "we're moving bookkeeping to Harrow & Pine, two late filings is enough",
         "On {d}, Vy switched the studio's bookkeeping to the firm Harrow & Pine after two late filings; the old files will be transferred at the end of the current quarter.",
         "bookkeeping-firm", ("Harrow & Pine",), ("td", OWNER, "Hiện giờ bên nào làm kế toán cho studio?"),
         old=(8, "mình thuê Én Bạc làm kế toán cho studio", "Ngày {d}, Vy quyết định thuê công ty Én Bạc làm dịch vụ kế toán cho studio.", "accounting-vendor", ("Én Bạc",))),
    need("h41", F, 21, "td", "Hạnh", "bên Orrin muốn tách hóa đơn, pháp nhân thứ hai là Orrin Mill Kitchen",
         "Hạnh ghi ngày {d}: khách Orrin xin tách hóa đơn cho hai pháp nhân, pháp nhân thứ hai tên Orrin Mill Kitchen.",
         "orrin-billing-entities", ("Orrin Mill Kitchen",), ("td", "Marek", "What's the second company Orrin wants invoiced?")),
    need("h42", C, 21, "qf", "Bảo", "I'll rotate the QF-APNS-9 push key before it lapses on 5/4",
         "Bảo promised on {d} to rotate the push notification key labelled QF-APNS-9 before it lapses on 5/4.",
         "push-key-rotation", ("QF-APNS-9",), ("qf", "Thảo", "Khóa thông báo đẩy ai sẽ đổi và trước ngày nào?")),
    need("h43", F, 21, "ds", "Thảo", "signage printer only takes files with 7 mm bleed",
         "Thảo reported on {d} that the Hoa Gạo signage printer only accepts files with a 7 mm bleed.",
         "signage-print-spec", ("7 mm bleed",), ("ds", "Lan Anh", "File biển hiệu gửi nhà in phải chừa lề tràn bao nhiêu?")),
    need("h44", P, 21, "inf", "Dung", "cảnh báo ổ đĩa đẩy vào kênh trực giùm, email ban đêm không ai đọc",
         "Dung dặn ngày {d}: cảnh báo ổ đĩa phải gửi vào kênh trực, đừng gửi email vì ban đêm không ai đọc.",
         "disk-alert-routing", ("kênh trực",), ("inf", OWNER, "Where should the disk space warnings be sent?")),
    need("h45", F, 22, "pal", OWNER, "only Lê Thị Mận at the library can sign off scope changes",
         "Vy recorded on {d} that Lê Thị Mận at the Hoa Gạo library is the only person who can approve scope changes.",
         "library-scope-approver", ("Lê Thị Mận",), ("qf", OWNER, "Muốn đổi phạm vi dự án thì bên thư viện ai duyệt?")),
    need("h46", C, 22, "ev", "Noor", "mình cam kết giao 300 túi vải in logo trước 6/4",
         "Ngày {d}, Noor cam kết giao 300 túi vải in logo cho hội chợ trước 6/4.",
         "fair-tote-bags", ("300 túi vải",), ("ev", "Hạnh", "When are the printed tote bags due in?")),
    need("h47", D, 22, "td", OWNER, "we pause dunning mail for the whole week of the harvest festival",
         "Vy agreed on {d} that Tidemark dunning emails pause for the whole week of the Đồi Mật harvest festival.",
         "dunning-pause", ("harvest festival",), ("td", "Khoa", "Tuần nào mình ngừng gửi mail nhắc nợ nhỉ?")),
    need("h48", C, 22, "pal", OWNER, "mình hứa gửi đề cương buổi đào tạo bảo mật cho cả studio trước 2/4",
         "Ngày {d}, Vy hứa sẽ gửi đề cương buổi đào tạo bảo mật cho cả studio trước 2/4.",
         "security-training-outline", ("đào tạo bảo mật",), ("pal", OWNER, "Do I still owe the team any material on staying safe online?")),
)

RECENT: tuple[Need, ...] = (
    need("h49", D, 23, "pal", OWNER, "retreat đổi sang đồi chè Suối Mơ nhé, chỗ cũ hết phòng",
         "Ngày {d}, Vy đổi địa điểm nghỉ dưỡng của studio sang đồi chè Suối Mơ vì chỗ cũ hết phòng.",
         "studio-retreat-place", ("Suối Mơ",), ("ev", OWNER, "Where did we land for the team retreat this year?"),
         old=(12, "retreat will be at Hồ Sen Xanh", "On {d}, Vy decided the studio retreat will be held at Hồ Sen Xanh.", "studio-retreat-place", ("Hồ Sen Xanh",)),
         again=(29, "nhớ nha, retreat là ở Suối Mơ", "Vy nhắc ngày {d} rằng buổi nghỉ dưỡng studio tổ chức ở Suối Mơ.")),
    need("h50", F, 23, "qf", "Quân", "cold start on the oldest test phone is 4.8 seconds, mostly fonts",
         "Quân measured on {d} that cold start on the oldest test phone takes 4.8 seconds, mostly spent loading fonts.",
         "cold-start-timing", ("4.8 seconds",), ("qf", "Priya", "Máy cũ nhất mở app mất bao lâu vậy?")),
    need("h51", P, 23, "td", "Khoa", "migration nào cũng chạy thử trên bản sao Mực Tím trước nha",
         "Khoa đề nghị ngày {d} rằng mọi migration của Tidemark phải chạy thử trên bản sao dữ liệu tên Mực Tím trước.",
         "migration-rehearsal", ("Mực Tím",), ("td", "Marek", "Which data copy should we rehearse schema changes on?")),
    need("h52", C, 24, "ds", "Lan Anh", "the A1 size menu poster goes to the printer on 7/4, on me",
         "Lan Anh committed on {d} to delivering the Orrin menu poster in A1 size to the printer on 7/4.",
         "orrin-menu-poster", ("A1 size",), ("ds", OWNER, "Poster thực đơn khổ lớn giao nhà in hôm nào?")),
    need("h53", F, 24, "inf", "Tomas", "load balancer đá nhầm máy khỏe vì health check chỉ chờ có 2 giây",
         "Tomas phát hiện ngày {d}: bộ cân bằng tải loại nhầm máy khỏe vì kiểm tra sức khỏe chỉ chờ có 2 giây.",
         "load-balancer-timeout", ("chờ có 2 giây",), ("inf", "Bảo", "Why did the balancer kick out healthy nodes?")),
    need("h54", P, 24, "pal", OWNER, "mails to Velmora: open with the ticket number, no exclamation marks",
         "On {d}, Vy said draft emails to Velmora should open with the ticket number and avoid exclamation marks.",
         "velmora-email-style", ("exclamation marks",), ("td", OWNER, "Soạn mail cho Velmora giúp mình, nhớ theo đúng lệ nhé")),
    need("h55", D, 24, "ev", "Dung", "bỏ cơm hộp, mời xe bánh mì tiệm Lò Than cho hội chợ",
         "Dung chốt ngày {d} bỏ cơm hộp buổi trưa, thay bằng xe bánh mì của tiệm Lò Than cho hội chợ sách.",
         "fair-lunch-plan", ("Lò Than",), ("ev", "Noor", "What did we settle on for lunch at the fair?")),
    need("h56", D, 25, "qf", "Thảo", "giảm cache offline còn 10 ngày lịch đặt thôi, máy cũ đầy bộ nhớ",
         "Ngày {d}, Thảo giảm bộ nhớ ngoại tuyến xuống còn 10 ngày lịch đặt vì máy cũ đầy dung lượng, người dùng phải gỡ ứng dụng khác mới mở được lịch.",
         "offline-storage-limit", ("10 ngày lịch đặt",), ("qf", "Quân", "How much booking history does offline mode keep now?"),
         old=(14, "offline mode caches 30 days of bookings", "On {d}, Thảo decided offline mode will cache 30 days of bookings.", "offline-cache-window", ("30 days of bookings",))),
    need("h57", C, 25, "pal", OWNER, "mình sẽ ký phụ lục hợp đồng với phòng khám trước thứ Ba 8/4",
         "{d}, Vy nhận sẽ ký phụ lục hợp đồng với phòng khám Sen Cạn trước thứ Ba 8/4.",
         "clinic-addendum", ("phụ lục hợp đồng",), ("pal", OWNER, "When do I have to sign the extra clinic paperwork?"),
         again=(28, "đừng quên phụ lục hợp đồng, hạn 8/4", "Vy nhắc ngày {d} rằng phụ lục hợp đồng Sen Cạn phải ký trước 8/4.")),
    need("h58", F, 25, "td", "Marek", "the bank sandbox account for reconciliation tests ends in 4471",
         "Marek confirmed on {d} that the bank's sandbox account for reconciliation tests ends in 4471.",
         "bank-sandbox-account", ("4471",), ("td", "Hạnh", "Tài khoản thử đối soát bên ngân hàng có đuôi số mấy?")),
    need("h59", P, 26, "ds", "Noor", "góp ý thiết kế thì ghim ngay trên bản vẽ nha, đừng chụp ảnh ném vào chat",
         "Ngày {d}, Noor muốn mọi góp ý thiết kế được ghim ngay trên bản vẽ, không gửi ảnh chụp trong chat.",
         "design-feedback-channel", ("ghim ngay trên bản vẽ",), ("ds", OWNER, "How does Noor want comments on mockups delivered?")),
    need("h60", C, 26, "inf", "Bảo", "I'll run a full restore drill from the Tuyết Tùng cold archive on 9/4",
         "Bảo promised on {d} to run a full restore drill from the cold archive Tuyết Tùng on 9/4.",
         "restore-drill", ("Tuyết Tùng",), ("inf", "Dung", "Bao giờ mình diễn tập khôi phục dữ liệu?")),
    need("h61", F, 26, "pal", OWNER, "new part-time tester Ngô Gia Hân starts 10/4, mornings only",
         "Vy noted on {d} that the new part-time tester Ngô Gia Hân starts on 10/4 and works mornings only.",
         "new-tester-start", ("Gia Hân",), ("qf", OWNER, "Bạn kiểm thử bán thời gian mới bắt đầu từ khi nào?")),
    need("h62", F, 27, "qf", "Priya", "calendar export dies when a room name has an ampersand, like Sách & Trà",
         "Priya found on {d} that the calendar export breaks whenever a room name contains an ampersand, as in Sách & Trà.",
         "calendar-export-bug", ("Sách & Trà",), ("qf", "Bảo", "Tên phòng kiểu nào làm xuất lịch bị lỗi vậy?")),
    need("h63", D, 27, "td", "Hạnh", "chốt: sổ Tidemark từ nay khóa vào ngày 26 hàng tháng",
         "Hạnh chốt ngày {d} đổi chu kỳ chốt sổ Tidemark sang ngày 26 hàng tháng.",
         "monthly-close-day", ("ngày 26 hàng tháng",), ("td", OWNER, "On which day do the books close each month now?")),
    need("h64", D, 27, "pal", OWNER, "pricing Sao Biển annual at 2.4 million dong per venue",
         "On {d}, Vy decided to price the Sao Biển annual plan at 2.4 million dong per venue.",
         "sao-bien-pricing", ("2.4 million",), ("td", OWNER, "Gói năm của Sao Biển mình định giá bao nhiêu mỗi điểm?")),
    need("h65", F, 28, "ev", "Hạnh", "phường chỉ cho dựng gian hàng đến 17 giờ Chủ nhật thôi",
         "Hạnh cho hay ngày {d} rằng giấy phép của phường chỉ cho dựng gian hàng đến 17 giờ ngày Chủ nhật.",
         "event-venue", ("đến 17 giờ",), ("ev", "Dung", "By what time must the booths come down according to the permit?")),
    need("h66", C, 28, "ds", "Thảo", "empty states with the paper heron mascot, shipping by 11/4",
         "Thảo committed on {d} to shipping the empty-state illustrations featuring the paper heron mascot by 11/4.",
         "empty-state-art", ("paper heron",), ("ds", "Noor", "Hình minh họa con cò giấy cho màn hình trống khi nào xong?")),
    need("h67", P, 28, "pal", OWNER, "nhắc việc thì nhắc mình lúc 8 giờ 15 tối, đừng chen giữa giờ làm",
         "Ngày {d}, Vy dặn khi nhắc việc hãy nhắc lúc 8 giờ 15 tối, đừng nhắc giữa giờ làm.",
         "vy-reminder-time", ("8 giờ 15 tối",), ("pal", OWNER, "What time do I like my nudges to arrive?")),
    need("h68", D, 29, "inf", OWNER, "retire the Rusty Kettle build runner after the 14/4 release",
         "Vy decided on {d} to retire the old build runner nicknamed Rusty Kettle after the 14/4 release.",
         "build-runner-retirement", ("Rusty Kettle",), ("inf", "Tomas", "Khi nào mình bỏ cái máy build cũ đi?")),
    need("h69", C, 29, "qf", "Quân", "trước trưa thứ Hai mình gửi bản 2.7.3 cho thủ thư thử",
         "Quân hứa ngày {d} sẽ gửi bản dựng 2.7.3 cho thủ thư Hoa Gạo thử trước trưa thứ Hai.",
         "librarian-test-build", ("2.7.3",), ("qf", "Priya", "Which build number is going to the librarians?")),
    need("h70", F, 30, "pal", OWNER, "heard Velmora moved their yearly audit to the third week of June",
         "On {d}, Vy learned that Velmora moves its yearly audit to the third week of June.",
         "velmora-audit-date", ("third week of June",), ("td", OWNER, "Đợt kiểm toán năm của Velmora dời sang lúc nào rồi?")),
    need("h71", P, 30, "td", "Khoa", "phần thanh toán em muốn review code thanh toán theo cặp, đừng duyệt một mình",
         "Khoa nói ngày {d} rằng muốn review code thanh toán theo cặp, không để một người tự duyệt.",
         "payment-review-style", ("review code thanh toán theo cặp",), ("td", "Hạnh", "How does Khoa want changes to payments looked over?")),
    need("h72", F, 30, "ds", "Lan Anh", "the bakery owner picked the oat box, sample OB-14",
         "Lan Anh reported on {d} that the bakery owner picked the oat-colored box, sample number OB-14.",
         "orrin-box-choice", ("OB-14",), ("ds", OWNER, "Chủ tiệm bánh chọn mẫu hộp số mấy?")),
)

NEEDS: tuple[Need, ...] = EARLY + MIDDLE + RECENT


def _place(home: str, thread: str = "") -> Place:
    channel = CHANNELS[home]
    return Place(channel.source, channel.name, thread)


def _kind(kind: ItemKind) -> Kind:
    return Kind.PREF if kind is ItemKind.PREFERENCE else Kind.WORK


def _moment_of_day(rng: random.Random, day: int) -> float:
    return day + round(rng.uniform(0.3, 0.97), 6)


def _fact_slot(rng: random.Random, item: Need, fact: Fact) -> Slot:
    note = fact.note.format(d=date_label(fact.day))
    thread = "" if item.home == "pal" else f"{item.home}-{fact.day}"
    planned = Planned(fact.key, _kind(item.kind), note, fact.topic, True)
    return Slot(_moment_of_day(rng, fact.day), _place(item.home, thread), item.speaker, fact.said, (planned,))


def _needed_slots(rng: random.Random) -> dict[str, list[Slot]]:
    slots: dict[str, list[Slot]] = {}
    for item in NEEDS:
        facts = (item.fact, *item.again)
        if item.old is not None:
            facts = (item.old.fact, *facts)
        for fact in facts:
            slots.setdefault(fact.key, []).append(_fact_slot(rng, item, fact))
    return slots


def _filler_draft(writer: Writer, channel: Channel, speaker: str, day: int, light: bool) -> Draft:
    date = date_label(day)
    if light or writer.rng.random() < 0.22:
        return writer.chatter(speaker, date)
    return writer.work(writer.rng.choice(channel.domains), speaker, date)


def _filler_turn(writer: Writer, day: int, serial: int, count: int) -> Slot:
    rng = writer.rng
    home = rng.choices(tuple(CHANNELS), weights=[c.weight for c in CHANNELS.values()])[0]
    channel = CHANNELS[home]
    speaker = rng.choice(channel.members)
    drafts = [_filler_draft(writer, channel, speaker, day, extra > 0) for extra in range(count)]
    notes = tuple(
        Planned(f"f-{day}-{serial}-{index}", draft.kind, draft.note, draft.topic, False)
        for index, draft in enumerate(drafts)
    )
    said = drafts[0].said if drafts else small_talk(rng, rng.choice(channel.members))
    threaded = home != "pal" and rng.random() < 0.35
    thread = f"{home}-{day}-{rng.randrange(4)}" if threaded else ""
    return Slot(_moment_of_day(rng, day), _place(home, thread), speaker, said, notes)


def _filler_day(writer: Writer, day: int, proposals: tuple[int, int]) -> list[Slot]:
    rng = writer.rng
    wanted = rng.randint(*proposals)
    slots: list[Slot] = []
    made = 0
    while made < wanted:
        count = 2 if rng.random() < 0.12 and wanted - made >= 2 else 1
        slots.append(_filler_turn(writer, day, len(slots), count))
        made += count
    for _ in range(rng.randint(9, 12)):
        slots.append(_filler_turn(writer, day, len(slots), 0))
    return slots


def _score(draw: float, needed: bool, mode: SalienceMode) -> float:
    if mode is SalienceMode.FLAT:
        return 0.6
    if mode is SalienceMode.NOISY:
        low, high = (0.45, 0.9) if needed else (0.15, 0.8)
        return round(low + (high - low) * draw, 3)
    if needed:
        return round(0.7 + 0.25 * draw, 3)
    return round(0.1 + 0.45 * draw**0.5, 3)


def _turn(slot: Slot, scores: random.Random, mode: SalienceMode) -> Turn:
    proposals = tuple(
        Proposal(n.key, n.kind, n.text, n.topic, _score(scores.random(), n.needed, mode)) for n in slot.notes
    )
    return Turn(slot.at, slot.place, slot.speaker, slot.said, slot.speaker == OWNER, proposals)


def _question(index: int, item: Need, said_at: float) -> Question:
    probe = Probe(
        QUESTION_START + index * QUESTION_STEP,
        _place(item.ask_home),
        item.asker,
        item.ask,
        item.asker == OWNER,
    )
    forbidden = ()
    if item.old is not None:
        forbidden = (Forbidden(item.old.fact.key, ForbiddenReason.SUPERSEDED, item.old.markers),)
    return Question(probe, Item(item.fact.key, item.kind, item.markers), said_at, forbidden)


def _lengthened(rng: random.Random, turn: Turn, sentences: int) -> Turn:
    proposals = tuple(
        replace(proposal, text=" ".join((proposal.text, *context(rng, vietnamese(proposal.text), sentences))))
        for proposal in turn.proposals
    )
    return replace(turn, proposals=proposals)


def build_history(seed: int, salience: SalienceMode, load: Load = Load.TYPICAL) -> History:
    volume = VOLUMES[load]
    rng = random.Random(f"history:{seed}")
    needed = _needed_slots(rng)
    writer = Writer(rng)
    slots = [slot for group in needed.values() for slot in group]
    for day in range(LAST_DAY + 1):
        slots.extend(_filler_day(writer, day, volume.proposals))
    slots.sort(key=lambda slot: slot.at)
    scores = random.Random(f"salience:{seed}")
    turns = tuple(_turn(slot, scores, salience) for slot in slots)
    if volume.context_sentences:
        padding = random.Random(f"context:{seed}")
        turns = tuple(_lengthened(padding, turn, volume.context_sentences) for turn in turns)
    questions = tuple(
        _question(index, item, min(slot.at for slot in needed[item.fact.key]))
        for index, item in enumerate(NEEDS)
    )
    return History(turns, questions, LAST_DAY)
