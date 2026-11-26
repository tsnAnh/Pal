from __future__ import annotations

import random
from dataclasses import dataclass

from scripts.memory_bench.filler import Writer, date_label, small_talk
from scripts.memory_bench.model import (
    Category,
    Forbidden,
    ForbiddenReason,
    Item,
    ItemKind,
    Kind,
    Place,
    Probe,
    Proposal,
    Scenario,
    Source,
    Split,
    Turn,
)

OWNER = "Vy"


@dataclass(frozen=True)
class Room:
    place: Place
    domain: str
    members: tuple[str, ...]


def slack(channel: str, thread: str = "") -> Place:
    return Place(Source.SLACK, channel, thread)


APP = Place(Source.PAL_APP, "pal-chat")
APP_ROOM = Room(APP, "team", (OWNER,))
MOBILE = Room(slack("quillfish-app"), "mobile", ("Quân", "Thảo", "Priya", "Bảo", OWNER))
BILLING = Room(slack("tidemark-billing"), "billing", ("Hạnh", "Marek", "Khoa", OWNER))
DESIGN = Room(slack("studio-design"), "design", ("Lan Anh", "Noor", "Thảo", OWNER))
INFRA = Room(slack("infra-ops"), "infra", ("Bảo", "Tomas", "Dung", OWNER))
EVENTS = Room(slack("events-desk"), "events", ("Dung", "Noor", "Hạnh", OWNER))
CLINIC = Room(slack("clinic-portal"), "clinic", ("Khoa", "Lan Anh", "Tomas", OWNER))
DEPOT = Room(slack("brindle-warehouse"), "warehouse", ("Marek", "Bảo", "Priya", OWNER))
LUNCH = Room(slack("an-trua"), "team", ("Quân", "Hạnh", "Noor", "Khoa", OWNER))


def say(at: float, place: Place, speaker: str, text: str, *notes: Proposal) -> Turn:
    return Turn(at, place, speaker, text, speaker == OWNER, notes)


def note(key: str, text: str, topic: str, salience: float, kind: Kind = Kind.WORK, sensitive: bool = False) -> Proposal:
    return Proposal(key, kind, text, topic, salience, sensitive)


def ask(at: float, place: Place, speaker: str, text: str, incident: bool = False) -> Probe:
    return Probe(at, place, speaker, text, speaker == OWNER, incident)


class Background:
    def __init__(self, scenario_id: str) -> None:
        self.scenario_id = scenario_id
        self.rng = random.Random(f"scenario:{scenario_id}")
        self.writer = Writer(self.rng)
        self.serial = 0

    def turns(
        self,
        room: Room,
        days: tuple[int, int],
        count: int,
        moments: bool = True,
        chatter_share: float = 0.2,
        salience: tuple[float, float] = (0.5, 0.85),
        distinct_topics: bool = False,
    ) -> list[Turn]:
        result = []
        for _ in range(count):
            day = self.rng.randint(*days)
            speaker = self.rng.choice(room.members)
            if self.rng.random() < chatter_share:
                draft = self.writer.chatter(speaker, date_label(day))
                score = self.rng.uniform(0.05, 0.55)
            else:
                draft = self.writer.work(room.domain, speaker, date_label(day))
                score = self.rng.uniform(*salience)
            self.serial += 1
            kind = draft.kind if moments else Kind.WORK
            topic = f"{draft.topic}-{self.serial}" if distinct_topics else draft.topic
            proposal = note(f"{self.scenario_id}-bg{self.serial}", draft.note, topic, round(score, 3), kind)
            result.append(say(self._moment(day), room.place, speaker, draft.said, proposal))
        return result

    def silent(self, place: Place, members: tuple[str, ...], days: tuple[int, int], count: int) -> list[Turn]:
        return [
            say(
                self._moment(self.rng.randint(*days)),
                place,
                self.rng.choice(members),
                small_talk(self.rng, self.rng.choice(members)),
            )
            for _ in range(count)
        ]

    def _moment(self, day: int) -> float:
        return day + round(self.rng.uniform(0.3, 0.9), 6)


def scenario(
    scenario_id: str,
    category: Category,
    split: Split,
    covers: str,
    turns: list[Turn],
    probe: Probe,
    expected: tuple[Item, ...] = (),
    forbidden: tuple[Forbidden, ...] = (),
    token_ceiling: int = 700,
) -> Scenario:
    ordered = tuple(sorted(turns, key=lambda turn: turn.at))
    return Scenario(scenario_id, category, split, covers, ordered, probe, expected, forbidden, token_ceiling)


def session_boundary() -> Scenario:
    sid = "s01-session-boundary"
    bg = Background(sid)
    first = slack("quillfish-app", "sync-monday")
    turns = [
        say(1.35, first, "Priya", "found it: sync only breaks after the tablet wakes from sleep. fix = re-fetch the room list on wake",
            note("s01-wake", "Priya established on 3/3 that the Quillfish sync bug appears only when a tablet wakes from sleep, and the agreed fix is to fetch the room list again on wake.", "tablet-sync-bug", 0.82)),
        say(1.36, first, "Quân", "ok mình test lại trên máy tính bảng hôm thứ Năm",
            note("s01-test", "Quân nhận ngày 3/3 sẽ thử lại bản sửa đồng bộ trên máy tính bảng thư viện vào thứ Năm.", "tablet-sync-test", 0.66)),
        say(2.5, MOBILE.place, "Thảo", "đồng bộ lịch trên web thì lỗi do múi giờ nhé, khác vụ máy tính bảng",
            note("s01-web", "Thảo báo ngày 4/3 rằng lỗi đồng bộ lịch trên bản web là do múi giờ, không liên quan đến máy tính bảng.", "web-sync-bug", 0.62)),
        say(2.7, DEPOT.place, "Bảo", "the warehouse scanner loses sync when the cradle is wet",
            note("s01-depot", "Bảo reported on 4/3 that the Brindle scanner loses sync whenever the charging cradle gets damp.", "scanner-sync-bug", 0.64)),
        *bg.turns(MOBILE, (0, 3), 22),
        *bg.turns(DEPOT, (0, 3), 8),
        *bg.silent(MOBILE.place, MOBILE.members, (0, 3), 10),
    ]
    probe = ask(4.4, slack("quillfish-app", "sync-thursday"), "Thảo", "Lỗi đồng bộ trên máy tính bảng hôm trước mình kết luận sửa thế nào ấy nhỉ?")
    return scenario(
        sid, Category.NEEDED, Split.DEV, "work context carried across days and threads", turns, probe,
        (Item("s01-wake", ItemKind.DECISION, ("wakes from sleep",)),),
        (Forbidden("s01-depot", ForbiddenReason.WRONG_AUDIENCE, ("charging cradle gets damp",)),),
        600,
    )


def changed_same_topic() -> Scenario:
    sid = "s02-changed-same-topic"
    bg = Background(sid)
    place = slack("tidemark-billing", "late-fees")
    turns = [
        say(2.4, place, "Hạnh", "chốt phí trễ hạn 1,5% một tháng nha",
            note("s02-old", "Hạnh chốt ngày 4/3 rằng phí trễ hạn trên Tidemark là 1,5% mỗi tháng.", "late-fee-rate", 0.8)),
        say(9.6, place, "Hạnh", "hạ phí trễ hạn xuống 0,8% nhé, khách nhỏ kêu nhiều quá",
            note("s02-new", "Ngày 11/3, Hạnh hạ phí trễ hạn của Tidemark xuống 0,8% mỗi tháng vì nhiều khách hàng nhỏ phàn nàn và hai khách đã dọa ngừng dùng.", "late-fee-rate", 0.85)),
        say(10.5, BILLING.place, "Marek", "early payment discount stays at 2% within ten days",
            note("s02-discount", "Marek confirmed on 12/3 that Tidemark keeps a 2% early-payment discount for invoices settled within ten days.", "early-payment-discount", 0.7)),
        say(12.4, BILLING.place, "Khoa", "phí xử lý hoàn tiền thì vẫn thu cố định 15 nghìn",
            note("s02-refund-fee", "Khoa ghi ngày 14/3 rằng phí xử lý mỗi lượt hoàn tiền vẫn thu cố định 15 nghìn đồng.", "refund-fee", 0.68)),
        *bg.turns(BILLING, (0, 14), 96),
        *bg.turns(APP_ROOM, (0, 14), 14),
        *bg.silent(BILLING.place, BILLING.members, (0, 14), 30),
    ]
    probe = ask(15.35, BILLING.place, "Marek", "Late fee on Tidemark — what rate do we charge now?")
    return scenario(
        sid, Category.NEEDED, Split.DEV, "decision changed later under the same topic slug", turns, probe,
        (Item("s02-new", ItemKind.DECISION, ("0,8%",)),),
        (Forbidden("s02-old", ForbiddenReason.SUPERSEDED, ("1,5%",)),),
    )


def commitment_deadline() -> Scenario:
    sid = "s03-commitment-deadline"
    bg = Background(sid)
    turns = [
        say(3.4, slack("studio-design", "catalogue"), "Noor", "I'll get the final Mây Tre catalogue layout to Giấy Sương by Thursday 20/3, promise",
            note("s03-layout", "On 5/3, Noor promised to deliver the final Mây Tre catalogue layout to the printer Giấy Sương by Thursday 20/3.", "catalogue-print-deadline", 0.9)),
        say(4.5, DESIGN.place, "Thảo", "bìa catalogue mình gửi khách xem hôm 18/3 nhé",
            note("s03-cover", "Thảo hẹn ngày 6/3 sẽ gửi khách xem phương án bìa catalogue Mây Tre vào ngày 18/3.", "catalogue-cover-review", 0.72)),
        say(5.5, DESIGN.place, "Noor", "the catalogue moodboard went out already",
            note("s03-moodboard", "Noor reported on 7/3 that the Mây Tre catalogue moodboard has already been sent and approved.", "catalogue-moodboard", 0.55)),
        *bg.turns(DESIGN, (0, 11), 18),
        *bg.silent(DESIGN.place, DESIGN.members, (0, 11), 6),
    ]
    probe = ask(12.45, DESIGN.place, OWNER, "When does Noor have to hand the catalogue layout over to the print shop?")
    return scenario(
        sid, Category.NEEDED, Split.DEV, "commitment with a deadline in a small store", turns, probe,
        (Item("s03-layout", ItemKind.COMMITMENT, ("Giấy Sương", "20/3")),),
        token_ceiling=500,
    )


def disagreement() -> Scenario:
    sid = "s04-disagreement"
    bg = Background(sid)
    place = slack("quillfish-app", "login-session")
    turns = [
        say(5.40, place, "Quân", "I'd keep people signed in for 60 days, students hate retyping passwords",
            note("s04-quan", "Quân argued on 7/3 that Quillfish should keep users signed in for 60 days, because students hate retyping their passwords.", "login-session-length", 0.78)),
        say(5.41, place, "Priya", "không được đâu, máy tính bảng thư viện dùng chung, phải hết phiên sau 8 tiếng",
            note("s04-priya", "Priya phản đối ngày 7/3: phiên đăng nhập Quillfish phải hết hạn sau 8 tiếng vì máy tính bảng ở thư viện được nhiều sinh viên dùng chung.", "login-session-length-objection", 0.79)),
        say(5.8, MOBILE.place, "Bảo", "password reset mail now expires in 30 minutes",
            note("s04-reset", "Bảo noted on 7/3 that the Quillfish password reset email link now expires after 30 minutes.", "password-reset-expiry", 0.6)),
        *bg.turns(MOBILE, (0, 6), 44),
        *bg.turns(CLINIC, (0, 6), 10),
        *bg.silent(place, MOBILE.members, (4, 6), 8),
    ]
    probe = ask(7.35, slack("quillfish-app", "planning"), OWNER, "Where do we disagree on how long a login should last?")
    return scenario(
        sid, Category.NEEDED, Split.DEV, "two people disagree in one thread and both positions are needed", turns, probe,
        (
            Item("s04-quan", ItemKind.FACT, ("60 days",)),
            Item("s04-priya", ItemKind.FACT, ("sau 8 tiếng",)),
        ),
    )


def owner_app_words_in_slack() -> Scenario:
    sid = "s05-app-words-in-slack"
    bg = Background(sid)
    turns = [
        say(2.38, APP, OWNER, "nhớ giúp: demo cho khách chỉ dùng bộ dữ liệu giả Làng Cói, tuyệt đối không dùng dữ liệu thật",
            note("s05-demo", "Vy dặn ngày 4/3 rằng mọi buổi demo cho khách chỉ dùng bộ dữ liệu giả Làng Cói, tuyệt đối không dùng dữ liệu thật của bất kỳ khách nào.", "demo-data-rule", 0.88)),
        say(3.5, DESIGN.place, OWNER, "for the bakery screenshots use the Peach Orchard sample set",
            note("s05-design", "Vy told the design channel on 5/3 that bakery demo screenshots should be filled with the sample set called Peach Orchard.", "demo-screenshot-data", 0.75)),
        say(4.4, MOBILE.place, "Thảo", "tài khoản demo thư viện đổi mật khẩu mỗi thứ Hai",
            note("s05-account", "Thảo cho biết ngày 6/3 rằng tài khoản demo dành cho thư viện được đổi mật khẩu vào mỗi thứ Hai.", "demo-account", 0.65)),
        *bg.turns(MOBILE, (0, 5), 24),
        *bg.turns(APP_ROOM, (0, 5), 8),
        *bg.turns(DESIGN, (0, 5), 8),
    ]
    probe = ask(6.4, slack("quillfish-app", "library-demo"), "Priya", "Mai demo cho thư viện thì mình đổ dữ liệu nào vào máy?")
    return scenario(
        sid, Category.NEEDED, Split.DEV, "owner words from the Pal app recalled in a Slack channel", turns, probe,
        (Item("s05-demo", ItemKind.DECISION, ("Làng Cói",)),),
        (Forbidden("s05-design", ForbiddenReason.WRONG_AUDIENCE, ("Peach Orchard",)),),
        500,
    )


def shared_topic_slug() -> Scenario:
    sid = "s06-shared-slug"
    bg = Background(sid)
    place = slack("events-desk", "opening-morning")
    turns = [
        say(6.4, place, "Hạnh", "xe tải chở sách tới cổng lúc 5 giờ 45 sáng khai mạc nha",
            note("s06-truck", "Hạnh báo ngày 8/3 rằng xe tải chở sách sẽ đến cổng hội chợ lúc 5 giờ 45 sáng ngày khai mạc.", "fair-logistics", 0.84)),
        say(7.5, place, "Dung", "forklift has to come from Cẩu Minh Phát, they're the only ones the ward lets in",
            note("s06-forklift", "Dung noted on 9/3 that the unloading forklift must be booked from Cẩu Minh Phát, the only operator the ward admits to the fair ground.", "fair-logistics", 0.8)),
        say(8.4, EVENTS.place, "Noor", "đội tình nguyện tập trung lúc 7 giờ",
            note("s06-volunteers", "Noor thông báo ngày 10/3 đội tình nguyện hội chợ tập trung lúc 7 giờ sáng ngày khai mạc.", "volunteer-call-time", 0.7)),
        say(9.4, EVENTS.place, "Hạnh", "the return truck leaves at nine in the evening on closing day",
            note("s06-return", "Hạnh noted on 11/3 that the return truck for unsold books leaves at nine in the evening on closing day.", "fair-return-truck", 0.68)),
        *bg.turns(EVENTS, (0, 13), 118),
        *bg.turns(APP_ROOM, (0, 13), 14),
        *bg.silent(EVENTS.place, EVENTS.members, (0, 13), 34),
    ]
    probe = ask(14.3, EVENTS.place, "Noor", "Opening morning unloading: what time is the truck in, and who do we book the forklift from?")
    return scenario(
        sid, Category.NEEDED, Split.DEV, "two different needed facts filed under one topic slug", turns, probe,
        (
            Item("s06-truck", ItemKind.FACT, ("5 giờ 45",)),
            Item("s06-forklift", ItemKind.FACT, ("Cẩu Minh Phát",)),
        ),
    )


def preference_beside_sensitive() -> Scenario:
    sid = "s07-preference-sensitive"
    bg = Background(sid)
    turns = [
        say(4.4, DESIGN.place, "Lan Anh", "when you critique my drafts, start with what works, then the problems please",
            note("s07-critique", "Lan Anh asked on 6/3 that critique of Lan Anh's drafts always start with what works before listing any problems.", "critique-style", 0.83, Kind.PREF)),
        say(8.6, DESIGN.place, "Lan Anh", "chiều thứ Tư mình đi trị liệu tâm lý vì dạo này lo âu, mọi người đừng nhắn nhé",
            note("s07-health", "Lan Anh chia sẻ ngày 10/3 rằng chiều thứ Tư Lan Anh đi trị liệu tâm lý vì chứng lo âu nên sẽ không trả lời tin nhắn.", "wednesday-absence", 0.72, sensitive=True)),
        say(9.5, DESIGN.place, "Noor", "I'd rather get written notes than calls",
            note("s07-noor", "Noor said on 11/3 that Noor prefers written review notes over a call.", "review-format", 0.7, Kind.PREF)),
        *bg.turns(DESIGN, (0, 13), 34),
        *bg.turns(APP_ROOM, (0, 13), 6),
        *bg.silent(DESIGN.place, DESIGN.members, (0, 13), 12),
    ]
    probe = ask(14.45, DESIGN.place, "Noor", "About to review Lan Anh's draft, how should I open? And is Wednesday afternoon ok for it?")
    return scenario(
        sid, Category.NEEDED, Split.DEV, "stated preference recalled while a sensitive note stays out", turns, probe,
        (Item("s07-critique", ItemKind.PREFERENCE, ("what works",)),),
        (Forbidden("s07-health", ForbiddenReason.SENSITIVE, ("trị liệu tâm lý",)),),
        600,
    )


def changed_new_topic() -> Scenario:
    sid = "s08-changed-new-topic"
    bg = Background(sid)
    place = slack("infra-ops", "logging")
    turns = [
        say(1.4, place, "Tomas", "app logs go to our own collector, Owlbarn",
            note("s08-old", "Tomas decided on 3/3 to ship the application logs to a self-hosted collector named Owlbarn.", "log-collector", 0.76)),
        say(11.5, place, "Tomas", "we're done with self-hosting, logs move to Fernwatch after those two disk-full outages",
            note("s08-new", "On 13/3, Tomas moved application log shipping to the managed service Fernwatch, after two outages in one week caused by a full disk on the old self-hosted box.", "observability-vendor", 0.84)),
        say(12.4, INFRA.place, "Dung", "log ứng dụng giữ 30 ngày thôi nhé",
            note("s08-retention", "Dung quy định ngày 14/3 rằng log ứng dụng chỉ được giữ trong 30 ngày.", "log-retention", 0.7)),
        *bg.turns(INFRA, (0, 15), 54),
        *bg.turns(CLINIC, (0, 15), 12),
        *bg.silent(INFRA.place, INFRA.members, (0, 15), 18),
    ]
    probe = ask(16.4, INFRA.place, "Dung", "Log của app giờ đẩy về đâu vậy mọi người?")
    return scenario(
        sid, Category.NEEDED, Split.TEST, "decision changed later and filed under a different topic slug", turns, probe,
        (Item("s08-new", ItemKind.DECISION, ("Fernwatch",)),),
        (Forbidden("s08-old", ForbiddenReason.SUPERSEDED, ("Owlbarn",)),),
    )


def app_preference_in_slack() -> Scenario:
    sid = "s09-app-preference"
    bg = Background(sid)
    turns = [
        say(3.35, APP, OWNER, "keep my Friday afternoons free, that's my focus block, no meetings",
            note("s09-friday", "On 5/3, Vy said Friday afternoons are reserved for Vy's own focused work and should never receive meetings.", "vy-focus-time", 0.86, Kind.PREF)),
        say(6.5, INFRA.place, OWNER, "book my infra reviews on Tuesday mornings only",
            note("s09-infra", "Vy told the infra channel on 8/3 to book Vy's infrastructure reviews on Tuesday mornings only.", "vy-review-slot", 0.74, Kind.PREF)),
        say(9.4, EVENTS.place, "Noor", "phỏng vấn diễn giả mỗi buổi khoảng 40 phút",
            note("s09-interview", "Noor ước tính ngày 11/3 mỗi buổi phỏng vấn diễn giả kéo dài khoảng 40 phút.", "speaker-interviews", 0.62)),
        *bg.turns(EVENTS, (0, 19), 22),
        *bg.turns(APP_ROOM, (6, 19), 8),
        *bg.silent(EVENTS.place, EVENTS.members, (0, 19), 8),
    ]
    probe = ask(20.4, EVENTS.place, "Noor", "Can I put a speaker interview with Vy on Friday afternoon?")
    return scenario(
        sid, Category.NEEDED, Split.TEST, "owner preference stated in the Pal app and applied in Slack", turns, probe,
        (Item("s09-friday", ItemKind.PREFERENCE, ("Friday afternoons",)),),
        (Forbidden("s09-infra", ForbiddenReason.WRONG_AUDIENCE, ("Tuesday mornings",)),),
        500,
    )


def words_stay_in_channel() -> Scenario:
    sid = "s10-own-channel"
    bg = Background(sid)
    turns = [
        say(5.4, slack("tidemark-billing", "orrin"), "Marek", "Orrin only pays when the purchase order number is printed on the invoice, learned that the hard way",
            note("s10-po", "Marek said on 7/3 that Orrin Bakery pays an invoice only when its purchase order number is printed on it, which already delayed two payments.", "orrin-payment-rule", 0.82)),
        say(7.5, DESIGN.place, "Thảo", "chủ tiệm Orrin còn nợ studio 47 triệu đấy, đừng nói ra ngoài",
            note("s10-debt", "Thảo báo trong kênh thiết kế ngày 9/3 rằng chủ tiệm bánh Orrin còn nợ studio 47 triệu đồng tiền thiết kế.", "orrin-outstanding", 0.8)),
        say(9.5, CLINIC.place, "Khoa", "clinic invoices need the tax code on page one",
            note("s10-clinic", "Khoa noted on 11/3 that Sen Cạn clinic invoices must show the tax code on the first page.", "clinic-invoice-rule", 0.7)),
        say(10.4, BILLING.place, "Hạnh", "hóa đơn Orrin gửi vào thứ Ba đầu tháng",
            note("s10-day", "Hạnh ghi ngày 12/3 rằng hóa đơn cho tiệm Orrin được gửi vào thứ Ba đầu tiên của tháng.", "orrin-invoice-day", 0.69)),
        *bg.turns(BILLING, (0, 12), 92),
        *bg.turns(DESIGN, (0, 12), 18),
        *bg.silent(BILLING.place, BILLING.members, (0, 12), 24),
    ]
    probe = ask(13.35, BILLING.place, "Hạnh", "Hóa đơn gửi tiệm Orrin cần lưu ý gì để bên đó chịu trả tiền?")
    return scenario(
        sid, Category.NEEDED, Split.TEST, "another person's words stay inside their own channel", turns, probe,
        (Item("s10-po", ItemKind.FACT, ("purchase order number",)),),
        (Forbidden("s10-debt", ForbiddenReason.WRONG_AUDIENCE, ("47 triệu",)),),
    )


def near_store_cap() -> Scenario:
    sid = "s11-near-cap"
    bg = Background(sid)
    turns = [
        say(0.31, slack("quillfish-app", "release-keys"), "Priya", "for the record: signing an Android release needs the Amber-Fox hardware token, locked drawer by the window",
            note("s11-token", "Priya recorded on 2/3 that signing a Quillfish Android release requires the hardware token labelled Amber-Fox, kept in the locked drawer by the window.", "android-release-signing", 0.82)),
    ]
    spread = (0.32, 0.86)
    for room, count in ((MOBILE, 230), (APP_ROOM, 60), (BILLING, 90), (DESIGN, 80), (INFRA, 90), (EVENTS, 70)):
        turns.extend(bg.turns(room, (0, 12), count, chatter_share=0.0, salience=spread, distinct_topics=True))
    turns.extend(bg.silent(MOBILE.place, MOBILE.members, (0, 12), 60))
    turns = [turns[0], *(turn for turn in turns[1:] if turn.at > turns[0].at)]
    probe = ask(13.4, MOBILE.place, "Quân", "Muốn ký bản Android để phát hành thì cần cái token nào, đang cất ở đâu?")
    return scenario(
        sid, Category.NEEDED, Split.TEST, "early fact must survive a store pushed past its cap", turns, probe,
        (Item("s11-token", ItemKind.FACT, ("Amber-Fox",)),),
    )


def session_boundary_cross_language() -> Scenario:
    sid = "s12-cross-language-session"
    bg = Background(sid)
    turns = [
        say(2.4, slack("events-desk", "pavilion"), "Noor", "pavilion manager: insurance certificate in ten days before the event or they cancel the booking",
            note("s12-insurance", "On 4/3, Noor learned that the pavilion manager requires the insurance certificate ten days before any event, otherwise the booking is cancelled.", "pavilion-paperwork", 0.86)),
        say(2.6, slack("events-desk", "pavilion"), "Hạnh", "tiền cọc nhà thi đấu thì hoàn lại sau một tuần",
            note("s12-deposit", "Hạnh ghi ngày 4/3 rằng tiền cọc thuê nhà thi đấu được hoàn lại một tuần sau sự kiện.", "pavilion-deposit", 0.65)),
        say(4.5, EVENTS.place, "Dung", "fire marshal wants the floor plan too",
            note("s12-floorplan", "Dung reported on 6/3 that the fire marshal wants the pavilion floor plan with both exits marked.", "fire-marshal-plan", 0.68)),
        *bg.turns(EVENTS, (0, 7), 32),
        *bg.turns(DEPOT, (0, 7), 6),
        *bg.silent(EVENTS.place, EVENTS.members, (0, 7), 10),
    ]
    probe = ask(8.35, slack("events-desk", "paperwork"), "Hạnh", "Hôm trước bên cho thuê nhà thi đấu đòi giấy tờ gì ấy nhỉ, phải nộp trước bao lâu?")
    return scenario(
        sid, Category.NEEDED, Split.TEST, "english note recalled by a vietnamese question in a later thread", turns, probe,
        (Item("s12-insurance", ItemKind.FACT, ("insurance certificate",)),),
        token_ceiling=600,
    )


def deadline_during_incident() -> Scenario:
    sid = "s13-incident"
    bg = Background(sid)
    turns = [
        say(1.6, INFRA.place, "Tomas", "kết luận khoa học: staging chỉ chịu chạy khi Dung đặt quả quýt cạnh máy 😂",
            note("s13-joke", "Ngày 3/3, cả kênh đùa rằng cụm staging chỉ chịu chạy khi Dung đặt một quả quýt bên cạnh máy chủ.", "staging-tangerine", 0.62, Kind.MOMENT)),
        say(5.4, slack("infra-ops", "payments-db"), "Bảo", "I'll have the failover runbook for the payments database written by 18/3",
            note("s13-runbook", "Bảo promised on 7/3 to finish writing the failover runbook for the payments database by 18/3.", "payments-db-failover", 0.9)),
        say(7.5, INFRA.place, "Dung", "máy dự phòng của staging đang tắt để tiết kiệm điện",
            note("s13-standby", "Dung báo ngày 9/3 rằng máy dự phòng của cụm staging đang được tắt để tiết kiệm điện.", "staging-standby", 0.66)),
        *bg.turns(INFRA, (0, 13), 44, moments=False),
        *bg.turns(APP_ROOM, (0, 13), 8, moments=False),
        *bg.silent(INFRA.place, INFRA.members, (0, 13), 12),
    ]
    probe = ask(14.05, INFRA.place, "Tomas", "Staging is down! Who owns the payments database failover doc, and when is it due?", incident=True)
    return scenario(
        sid, Category.NEEDED, Split.TEST, "commitment needed during an incident while a joke stays out", turns, probe,
        (Item("s13-runbook", ItemKind.COMMITMENT, ("failover runbook", "18/3")),),
        (Forbidden("s13-joke", ForbiddenReason.INCIDENT, ("quả quýt",)),),
        500,
    )


def disagreement_cross_language() -> Scenario:
    sid = "s14-logo-disagreement"
    bg = Background(sid)
    place = slack("studio-design", "craft-logo")
    turns = [
        say(7.40, place, "Noor", "mình nghĩ nên giữ logo hình lá tre, khách cũ quen rồi",
            note("s14-noor", "Noor muốn ngày 9/3 giữ logo Mây Tre hình lá tre vì khách hàng cũ đã quen nhận ra cửa hàng qua hình đó.", "may-tre-logo", 0.77)),
        say(7.41, place, "Thảo", "disagree, the leaf reads like a tea brand. switch to a woven basket mark",
            note("s14-thao", "Thảo disagreed on 9/3 and wants the Mây Tre logo changed to a woven basket mark, because the current leaf reads like a tea brand.", "may-tre-logo", 0.77)),
        say(8.5, DESIGN.place, "Lan Anh", "logo phụ để sau, ưu tiên bao bì",
            note("s14-secondary", "Lan Anh đề nghị ngày 10/3 để logo phụ của Mây Tre lại sau và ưu tiên làm bao bì trước.", "secondary-logo", 0.64)),
        *bg.turns(DESIGN, (0, 10), 112),
        *bg.turns(CLINIC, (0, 10), 14),
        *bg.silent(place, DESIGN.members, (7, 10), 20),
    ]
    probe = ask(11.4, DESIGN.place, OWNER, "What are the two sides in the argument about the craft shop's logo?")
    return scenario(
        sid, Category.NEEDED, Split.TEST, "disagreement noted in two languages and asked in english", turns, probe,
        (
            Item("s14-noor", ItemKind.FACT, ("hình lá tre",)),
            Item("s14-thao", ItemKind.FACT, ("woven basket",)),
        ),
    )


def irrelevant_turn() -> Scenario:
    sid = "s15-irrelevant"
    bg = Background(sid)
    turns = [
        say(4.4, APP, OWNER, "invoice numbers get the prefix ZX-77 from now",
            note("s15-prefix", "Vy decided on 6/3 that the studio's own invoices are numbered with the prefix ZX-77.", "invoice-prefix", 0.84)),
        say(5.5, EVENTS.place, "Dung", "đặt bún chả cho đội dựng gian hàng ở quán Hương Cau nhé",
            note("s15-catering", "Dung chốt ngày 7/3 đặt bún chả của quán Hương Cau cho đội dựng gian hàng hội chợ.", "fair-crew-lunch", 0.7)),
        *bg.turns(EVENTS, (0, 8), 14),
        *bg.turns(BILLING, (0, 8), 14),
        *bg.turns(APP_ROOM, (0, 8), 10),
        *bg.silent(LUNCH.place, LUNCH.members, (0, 8), 22),
    ]
    probe = ask(9.49, LUNCH.place, "Quân", "Trưa nay ăn bún chả hay cơm tấm đây mọi người?")
    return scenario(
        sid, Category.IRRELEVANT, Split.DEV, "lunch chatter must add no memory tokens", turns, probe,
        forbidden=(
            Forbidden("s15-prefix", ForbiddenReason.IRRELEVANT, ("ZX-77",)),
            Forbidden("s15-catering", ForbiddenReason.WRONG_AUDIENCE, ("Hương Cau",)),
        ),
        token_ceiling=0,
    )


def expired_note() -> Scenario:
    sid = "s16-expiry"
    bg = Background(sid)
    turns = [
        say(2.45, INFRA.place, "Dung", "mã wifi tạm cho đoàn kiểm toán hôm nay là Cỏ May 12",
            note("s16-temp", "Dung nhắn ngày 4/3 rằng mã wifi tạm cho đoàn kiểm toán đang ghé là Cỏ May 12.", "guest-wifi-code", 0.36)),
        say(3.4, INFRA.place, "Dung", "quy định luôn: khách tới studio dùng mạng riêng, mã do lễ tân cấp và đổi mỗi thứ Hai",
            note("s16-rule", "Dung quy định ngày 5/3 rằng khách đến studio dùng mạng wifi dành riêng, mã do lễ tân cấp và được đổi mỗi thứ Hai.", "guest-wifi-policy", 0.85)),
        *bg.turns(INFRA, (0, 6), 18),
        *bg.turns(INFRA, (12, 21), 16),
        *bg.silent(INFRA.place, INFRA.members, (0, 21), 14),
    ]
    probe = ask(22.4, INFRA.place, "Tomas", "Where do visitors get the wifi code, and what was the one we gave the auditors the other day?")
    return scenario(
        sid, Category.EXPIRY, Split.DEV, "unused low-salience note expires after two weeks", turns, probe,
        (Item("s16-rule", ItemKind.DECISION, ("lễ tân cấp",)),),
        (Forbidden("s16-temp", ForbiddenReason.EXPIRED, ("Cỏ May",)),),
        500,
    )


def returning_joke() -> Scenario:
    sid = "s17-joke-returns"
    bg = Background(sid)
    turns = [
        say(1.55, MOBILE.place, "Priya", "official rule: no release is blessed until Admiral Quack sits on the test tablet 🦆",
            note("s17-duck", "On 3/3, the team joked that no Quillfish release is blessed until Quân's rubber duck, Admiral Quack, has been seated on the test tablet.", "release-duck-ritual", 0.65, Kind.MOMENT)),
        say(22.6, MOBILE.place, "Bảo", "bản build mới đặt tên bánh chuối đi, chín cái là nát 😂",
            note("s17-banana", "Hôm 24/3, Bảo đùa rằng bản dựng mới nên tên là bánh chuối vì cứ vừa chín là nát.", "build-nickname-joke", 0.68, Kind.MOMENT)),
        *bg.turns(MOBILE, (2, 23), 26, moments=False),
        *bg.silent(MOBILE.place, MOBILE.members, (2, 23), 14),
    ]
    probe = ask(25.65, MOBILE.place, "Quân", "About to hit the release button, are we missing any ritual 😄")
    return scenario(
        sid, Category.JOKE, Split.DEV, "old joke may come back after three weeks, a fresh one may not", turns, probe,
        (Item("s17-duck", ItemKind.JOKE, ("Admiral Quack",)),),
        (Forbidden("s17-banana", ForbiddenReason.TOO_RECENT, ("bánh chuối",)),),
        400,
    )


def long_thread() -> Scenario:
    sid = "s18-long-thread"
    bg = Background(sid)
    place = slack("tidemark-billing", "ledger-cutover")
    room = Room(place, "billing", BILLING.members)
    early = [
        say(4.301, place, "Khoa", "decided: after cutover the old ledger stays read-only for 45 days",
            note("s18-readonly", "Khoa decided on 6/3, in the cutover thread, that the old Tidemark ledger stays read-only for 45 days after the switch so disputes can still be traced.", "ledger-cutover-plan", 0.86)),
        say(4.302, place, "Hạnh", "em nhận đối chiếu số dư đầu kỳ với tệp mẫu Hồng Hạc trước khi chuyển",
            note("s18-opening", "Hạnh nhận ngày 6/3 sẽ đối chiếu số dư đầu kỳ với tệp mẫu Hồng Hạc trước khi chuyển sổ.", "opening-balance-check", 0.82)),
    ]
    chatter = bg.turns(room, (4, 6), 86, salience=(0.4, 0.85))
    quiet = bg.silent(place, BILLING.members, (4, 6), 132)
    later = [turn for turn in (*chatter, *quiet) if turn.at > 4.31]
    probe = ask(6.96, place, "Marek", "Quay lại đầu thread chút: sổ cũ khóa chỉ đọc bao lâu, và ai đối chiếu số dư đầu kỳ bằng tệp nào?")
    return scenario(
        sid, Category.LONG_THREAD, Split.TEST, "facts from the start of a two hundred turn thread", early + later, probe,
        (
            Item("s18-readonly", ItemKind.DECISION, ("45 days",)),
            Item("s18-opening", ItemKind.COMMITMENT, ("Hồng Hạc",)),
        ),
    )


def duplicated_fact() -> Scenario:
    sid = "s19-duplicate"
    bg = Background(sid)
    said = (
        (2.4, "Hạnh", "cổng soát vé mở lúc 7:20 sáng nha", "Hạnh báo ngày 4/3 rằng cổng soát vé của hội chợ sách mở lúc 7:20 sáng.", "fair-gate-time"),
        (3.5, "Dung", "reminder, ticket gate opens 7:20", "Dung reminded the channel on 5/3 that the book fair ticket gate opens at 7:20 in the morning.", "gate-opening"),
        (5.4, "Noor", "ai hỏi thì giờ mở cổng vé là 7:20 nhé", "Noor nhắc ngày 7/3 rằng giờ mở cổng vé hội chợ sách là 7:20 sáng.", "book-fair-schedule"),
        (8.5, "Hạnh", "flyers now print 7:20 as the gate time", "Hạnh confirmed on 10/3 that the printed flyers show 7:20 as the time the fair's ticket gate opens.", "flyer-details"),
        (9.6, "Dung", "chốt lại lần nữa, 7:20 mở cổng vé", "Dung chốt lại ngày 11/3: cổng vé hội chợ sách mở đúng 7:20 sáng.", "fair-gate-time"),
    )
    turns = [
        say(at, EVENTS.place, speaker, text, note("s19-gate", body, topic, 0.74))
        for at, speaker, text, body, topic in said
    ]
    turns += [
        say(4.4, EVENTS.place, "Noor", "suppliers use the back gate from 6:00",
            note("s19-back", "Noor noted on 6/3 that suppliers may enter through the back gate of the fair from 6:00.", "supplier-gate", 0.72)),
        say(6.4, EVENTS.place, "Hạnh", "quầy vé đóng lúc 18:30",
            note("s19-close", "Hạnh ghi ngày 8/3 rằng quầy vé hội chợ đóng lúc 18:30 mỗi ngày.", "ticket-desk-close", 0.7)),
        *bg.turns(EVENTS, (0, 11), 40),
        *bg.silent(EVENTS.place, EVENTS.members, (0, 11), 10),
    ]
    probe = ask(12.35, EVENTS.place, OWNER, "Mấy giờ thì cổng vé hội chợ mở cửa nhỉ?")
    return scenario(
        sid, Category.DUPLICATE, Split.TEST, "one fact repeated five times under varied topics", turns, probe,
        (Item("s19-gate", ItemKind.FACT, ("7:20",)),),
        token_ceiling=400,
    )


def joke_must_not_return() -> Scenario:
    sid = "s20-joke-blocked"
    bg = Background(sid)
    turns = [
        say(2.55, EVENTS.place, "Dung", "con mèo quán cà phê tầng trệt mới là giám đốc sáng tạo thật sự đó 😹",
            note("s20-cat", "Hôm 4/3 ở kênh sự kiện, Dung đùa rằng con mèo của quán cà phê tầng trệt mới là giám đốc sáng tạo thật sự của studio.", "cafe-cat-director", 0.66, Kind.MOMENT)),
        say(3.6, DESIGN.place, "Noor", "honestly my divorce lawyer picks better fonts than this whole studio 😅",
            note("s20-lawyer", "On 5/3, Noor joked that Noor's divorce lawyer has better taste in fonts than the whole studio.", "fonts-joke", 0.64, Kind.MOMENT, sensitive=True)),
        say(4.4, DESIGN.place, "Thảo", "font thực đơn phải mua giấy phép bên Quiet Nib trước khi in",
            note("s20-license", "Thảo ghi ngày 6/3 rằng phông chữ cuối cùng của thực đơn Mây Tre phải mua giấy phép từ xưởng chữ Quiet Nib trước khi in.", "menu-font-license", 0.85)),
        *bg.turns(DESIGN, (0, 22), 30, moments=False),
        *bg.turns(EVENTS, (0, 22), 12, moments=False),
        *bg.silent(DESIGN.place, DESIGN.members, (0, 22), 10),
    ]
    probe = ask(24.5, DESIGN.place, OWNER, "Phông chữ thực đơn còn vướng gì trước khi in không? Mà studio mình ai mới là giám đốc sáng tạo vậy 😄")
    return scenario(
        sid, Category.MUST_NOT, Split.TEST, "jokes from another channel or on a sensitive matter never come back", turns, probe,
        (Item("s20-license", ItemKind.FACT, ("Quiet Nib",)),),
        (
            Forbidden("s20-cat", ForbiddenReason.WRONG_AUDIENCE, ("con mèo của quán cà phê",)),
            Forbidden("s20-lawyer", ForbiddenReason.SENSITIVE, ("divorce lawyer",)),
        ),
        500,
    )


SCENARIOS: tuple[Scenario, ...] = (
    session_boundary(),
    changed_same_topic(),
    commitment_deadline(),
    disagreement(),
    owner_app_words_in_slack(),
    shared_topic_slug(),
    preference_beside_sensitive(),
    changed_new_topic(),
    app_preference_in_slack(),
    words_stay_in_channel(),
    near_store_cap(),
    session_boundary_cross_language(),
    deadline_during_incident(),
    disagreement_cross_language(),
    irrelevant_turn(),
    expired_note(),
    returning_joke(),
    long_thread(),
    duplicated_fact(),
    joke_must_not_return(),
)
