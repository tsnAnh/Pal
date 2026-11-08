import argparse
import asyncio
import importlib.util
import json
import os
import sys
import uuid
from collections import namedtuple
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

PRIMARY_SLUG = "default"
BOT_CHAT_TITLE = "Bot Chat"
BOT_META_KEY = "hermes-bots"
SESSION_SOURCE = "gui"
HOME_MARKER = "hermes-ios-e2e."
REPLY_GAP = timedelta(minutes=2)
EXCHANGE_GAP = timedelta(minutes=25)


@dataclass(frozen=True)
class Look:
    shape: str
    color: str


@dataclass(frozen=True)
class Recency:
    days_back: int = 0
    clock: str = ""
    minutes_ago: int = 0

    def resolve(self, now):
        if not self.clock:
            return now - timedelta(minutes=self.minutes_ago)
        hour, minute = map(int, self.clock.split(":"))
        return (now - timedelta(days=self.days_back)).replace(hour=hour, minute=minute, second=0, microsecond=0)


@dataclass(frozen=True)
class Turn:
    role: str
    text: str
    gap_before: timedelta | None = None
    display_kind: str | None = None


def as_turn(entry):
    return entry if isinstance(entry, Turn) else Turn(role=entry[0], text=entry[1])


@dataclass(frozen=True)
class Routine:
    title: str
    prompt: str
    schedule: str


@dataclass(frozen=True)
class Shared:
    role: str
    text: str
    days_back: int
    clock: str = "10:15"
    media: str = ""


@dataclass(frozen=True)
class Bot:
    slug: str
    title: str
    look: Look | None
    last_message: Recency
    conversation: tuple
    pinned: bool = False
    routines: tuple[Routine, ...] = ()
    shared: tuple[Shared, ...] = ()


BOTS = (
    Bot(
        slug="default",
        title="chó grok bot",
        look=Look(shape="blobatar:grok:round", color="#ffffff"),
        pinned=True,
        last_message=Recency(minutes_ago=45),
        conversation=(
            ("user", "Chào em, hôm nay anh cần em gom lại việc của cả đội bot giúp anh."),
            ("assistant", "Dạ anh. Em đang điều phối 7 bot:\n\n- **chó UA** lo creative quảng cáo\n- **chó ai image gen** gen ảnh\n- **Upwork Hunter** săn job\n- **chó research app** nghiên cứu thị trường app\n- **chó hóng hớt** bản tin AI mỗi sáng\n- **Market Researcher** định vị sản phẩm\n- **chó Định** báo cáo số liệu\n\nAnh muốn em hỏi bot nào trước?"),
            ("user", "Hỏi chó UA xem tiến độ bộ ảnh tháng 12 tới đâu rồi."),
            ("assistant", "Em đã nhắn chó UA. Bot trả lời là đã giao làm 12 ảnh, ước tính xong trong 20 phút. Anh xem chi tiết ở [bảng creative](https://www.notion.so/creative-ua-t12) nhé."),
            ("user", "Tốt. Chiều nay nhắc anh duyệt ảnh."),
            ("assistant", "Dạ anh, em đã đặt nhắc lúc 15:00. Có gì thay đổi em báo anh ngay."),
            Turn("user", "Fren fix rồi", gap_before=timedelta(hours=14)),
            Turn("assistant", "Ok anh. Fren đã fix rồi thì còn lại Kirumi với thẻ Google Cloud của ScribeFoundry thôi nha.", gap_before=timedelta(minutes=1)),
            Turn("assistant", "Anh ơi, sáng nay (khoảng 8:03, giờ VN) Google Payments gửi mail \"Add Brazil tax info\", yêu cầu anh bổ sung thông tin thuế Brazil vì app trên Play đã có thu nhập ở đó. Anh khai ở [Google Payments](https://pay.google.com/) nha. Thẻ GCP với vụ thanh toán bị giữ thì vẫn như em báo hôm trước.", gap_before=timedelta(hours=15)),
            Turn("assistant", "Anh ơi, LastPass Premium của anh không bật tự gia hạn nên sẽ hết hạn ngày 6/12/2026. Nếu còn dùng thì anh vào [LastPass](https://www.lastpass.com/) gia hạn hoặc bật auto-renew nha.", gap_before=timedelta(minutes=23)),
            Turn("user", "éo, tau dùng 1password", gap_before=timedelta(minutes=8)),
            Turn("assistant", "Ok anh, vậy cứ để LastPass hết hạn. Em ghi nhớ anh dùng 1Password rồi, lần sau không nhắc LastPass nữa.", gap_before=timedelta(minutes=1)),
            Turn("user", "ý là đợi hết lastpass t sẽ qua 1password", gap_before=timedelta(hours=9)),
            Turn("assistant", "À hiểu rồi anh, dùng LastPass tới khi hết hạn ngày 6/12 rồi mới chuyển qua 1Password. Em sửa lại ghi nhớ rồi, lần sau cũng không nhắc gia hạn LastPass nữa.", gap_before=timedelta(minutes=1)),
        ),
        routines=(
            Routine("Nhắc thanh toán và gia hạn", "Kiểm tra email thanh toán và gia hạn, tóm tắt cái nào sắp hết hạn.", "weekdays at 8:30am"),
            Routine("Xử lý store review", "Đọc review mới trên App Store và Google Play rồi gợi ý trả lời.", "weekdays at 3pm"),
        ),
        shared=(
            Shared("assistant", "Anh xem trang giá ở https://www.apple.com/app-store/ và tài liệu ở https://developer.apple.com/documentation/swiftui nhé.", 2),
            Shared("assistant", "Em lưu lại ảnh mô phỏng giao diện ở đây. MEDIA:{media}", 3, "16:40", "library-sample.png"),
            Shared("assistant", "Bản tin hôm nay: https://news.ycombinator.com/ và https://github.com/trending.", 9),
            Shared("assistant", "Tài liệu cũ: https://www.python.org/ và https://www.wikipedia.org/ để tham khảo thêm.", 26),
        ),
    ),
    Bot(
        slug="cho-ua",
        title="chó UA",
        look=Look(shape="blobatar:ua:organic", color="#ed0a37"),
        last_message=Recency(minutes_ago=12),
        conversation=(
            Turn("user", "Em ơi, anh cần 4 ảnh App Store cho app Fren, bán ý tưởng chính là wallpaper và chibi trên home screen. Lên brief giúp anh."),
            Turn("assistant", "Dạ anh. Nội dung 4 ảnh:\n\n1. **\u201cYour wallpaper has a roommate\u201d** \u2014 Giới thiệu ngay wallpaper có người sống bên trong. Một màn home nổi bật, thấy rõ căn phòng và nhân vật. Đây là ảnh bán ý tưởng chính.\n2. **\u201cHer little moments, on your screen\u201d** \u2014 Đưa người xem gần hơn với Fren đang trang trí cây. Dùng cảnh và chi tiết chuyển động làm trọng tâm, không lặp layout home của ảnh 1. Không thêm hành động app chưa có.\n3. **\u201cThree rooms. One cozy Christmas.\u201d** \u2014 Cho thấy ba không gian bedroom, workshop, igloo bằng bố cục có chiều sâu, một cảnh chính và hai cảnh phụ. Không biến thành catalog cửa hàng hay bảng nút mua.\n4. **\u201cMeet your tiny home-screen companion\u201d** \u2014 Tập trung vào chibi Fren giữa các icon và tương tác home đã có. Phân biệt rõ với Fren trong wallpaper ở ảnh 1; không dùng cô gái minh họa lớn để thay cho tính năng.\n\n**Không làm:** khoanh đỏ, dây nối, kính lúp, collage screenshot có chữ li ti, clipart dán bốn góc, UI giả có tính năng không tồn tại, claim miễn phí hoặc trial.\n\n**Bàn giao:** 4 ảnh 1080\u00d71920 và một bảng xem cả bộ. Trước khi gửi, so trực tiếp với reference về độ rõ, bố cục và tính nhất quán; ghi rõ phần nào là mockup để kiểm tính chính xác."),
            Turn("user", "cái 3, ko cần list 3 rooms làm gì cho mệt", gap_before=timedelta(minutes=25)),
            Turn("assistant", "Ừ anh, #3 chỉ cần một cảnh igloo thật đẹp với headline **\u201cFind your cozy corner\u201d**. Bỏ danh sách, thumbnail và tên ba phòng; bán cảm giác có một góc riêng, không liệt kê tính năng.", gap_before=timedelta(minutes=1)),
            Turn("user", "thees sau tao theem vaof thif sao", gap_before=timedelta(minutes=1)),
            Turn("assistant", "Đúng anh, ghi \u201c3 rooms\u201d thì thêm phòng lại phải sửa ảnh. Brief #3 đổi thành **\u201cFind your cozy corner\u201d**, minh họa một phòng thôi, không chốt số lượng hay liệt kê tên phòng.", gap_before=timedelta(minutes=1)),
            Turn("user", "Maf sao cos 4 cai screenshot thoi?", gap_before=timedelta(minutes=1)),
            Turn("assistant", "Vì em tự rút từ 8 xuống 4 để bỏ nội dung lặp, nhưng lại thu hẹp bộ quá mức. Không phải giới hạn của store. Em sẽ lên lại mạch 8 ảnh với 8 ý riêng, không kéo dài bằng cách liệt kê từng phòng hay lặp màn hình home.", gap_before=timedelta(minutes=1)),
            Turn("user", "6 casi ddi, lam 2 bo experiment", gap_before=timedelta(minutes=1)),
            Turn("assistant", "Chốt anh: 2 bộ, mỗi bộ 6 ảnh. Em giữ cùng nội dung và thứ tự, chỉ đổi hướng thiết kế giữa hai bộ để test rõ; không ghi số lượng phòng. Làm xong em gửi cả hai bộ duyệt, chưa chạy experiment.", gap_before=timedelta(minutes=1)),
            Turn("user", "Message from \U0001f916 chó ai image gen (@cho-ai-image-gen): Đã nhận brief 2 bộ, mỗi bộ 6 ảnh. Em bắt đầu gen ngay, bản nháp đầu sẽ có sau ít phút.", gap_before=timedelta(hours=6), display_kind="internal_notification"),
            Turn("user", "[IMPORTANT: Background process proc_7f3a matched watch pattern \"batch complete\".\nCommand: gen_images.sh --sets 2\nMatched output:\nbatch complete: 12 files]", gap_before=timedelta(minutes=3), display_kind="internal_notification"),
            Turn("assistant", "Đã giao làm 12 ảnh: bộ A pastel sáng, bộ B Giáng sinh tông đậm. Cùng thông điệp để so thiết kế, không trộn thêm thay đổi nội dung giữa hai bộ. Chi tiết xem [bảng creative](https://www.notion.so/creative-ua-t12).", gap_before=timedelta(minutes=1)),
        ),
    ),
    Bot(
        slug="cho-ai-image-gen",
        title="chó ai image gen",
        look=Look(shape="blobatar:ai-image-gen:round", color="#ed0a37"),
        last_message=Recency(days_back=1, clock="22:48"),
        conversation=(
            ("user", "Gen cho anh logo mascot con chó cầm điện thoại, style flat, nền trong."),
            ("assistant", "Dạ, em đã tạo 4 biến thể logo flat, nền trong suốt:\n\n1. Corgi cầm điện thoại, viền dày\n2. Shiba tông cam\n3. Chó đen tối giản\n4. Chó hoạt hình kiểu sticker\n\nAnh chọn số nào em tinh chỉnh tiếp?"),
            ("user", "Số 2, đổi tông sang xanh mint."),
            ("assistant", "Xong rồi anh, bản mint đây. Em lưu PNG 2048px và SVG trong thư mục chung của đội."),
            ("user", "Em xem tin nhắn từ chó UA đi, có brief mới."),
            ("user", "Message from 🤖 chó UA (@cho-ua): Anh CHỐT mới: 6 ảnh mỗi bộ, bỏ bộ C tối giản, giữ bộ A và B. Em sẽ gen lại theo brief này, ước tính 20 phút. Chi tiết xem [brief mới](https://www.notion.so/creative-ua-t12)."),
        ),
    ),
    Bot(
        slug="upwork-hunter",
        title="Upwork Hunter",
        look=Look(shape="blobatar:upwork:capsule", color="#10dc69"),
        last_message=Recency(days_back=1, clock="18:20"),
        conversation=(
            ("user", "Quét Upwork giúp anh job React Native, budget từ $2000, đăng trong 24 giờ qua."),
            ("assistant", "Em tìm được 3 job phù hợp trên [Upwork](https://www.upwork.com/nx/search/jobs/?q=react%20native):\n\n- **Mobile app fitness**: fixed $3,500, client đã tiêu $40K\n- **Fintech dashboard RN**: $60 một giờ, client đã xác minh\n- **Marketplace app**: fixed $2,200\n\nEm đã chấm điểm phù hợp, 2 job đầu đáng apply nhất."),
            ("user", "Soạn cover letter cho job fitness. Giọng thân thiện, ngắn."),
            ("assistant", "Em soạn xong, 140 từ, mở đầu bằng điểm liên quan tới app fitness anh từng làm. Em lưu bản nháp, chưa gửi. Anh duyệt rồi em mới submit nhé."),
            ("user", "Gửi đi. Rồi nhắn anh khi client trả lời."),
            ("assistant", "Đã gửi proposal. Em sẽ theo dõi inbox Upwork mỗi 30 phút và báo anh ngay khi có phản hồi."),
            ("user", "Có client nào trả lời chưa em?"),
            ("assistant", "Chưa anh. Tin cuối vẫn là tin anh gửi lúc 17:33 (giờ VN), client chưa mở proposal. Em vẫn đang theo dõi và sẽ báo ngay khi có động tĩnh."),
        ),
    ),
    Bot(
        slug="cho-research-app",
        title="chó research app",
        look=Look(shape="blobatar:research:hexagon", color="#ee0d8f"),
        last_message=Recency(days_back=2, clock="16:05"),
        conversation=(
            ("user", "Nghiên cứu giúp anh các app journaling đang top ở App Store Việt Nam."),
            ("assistant", "Em đã xem top 20 mục Lifestyle, các app journaling nổi bật:\n\n- [Day One](https://dayoneapp.com/): nhật ký đa phương tiện, đồng bộ tốt\n- [Reflectly](https://reflectly.app/): trò chuyện hỏi đáp hằng ngày\n- Journey: tối giản, hỗ trợ nhiều nền tảng\n\nPhần lớn đều thu phí theo năm, giá khoảng $25 đến $35."),
            ("user", "Soully nằm ở đâu so với đám này?"),
            ("assistant", "Soully khác ở chỗ viết chung và phản tỉnh cùng nhau. Chưa app nào trong top làm hướng này. Rủi ro là người dùng chưa quen viết nhật ký chung nên cần onboarding rõ."),
            ("user", "Tóm 3 điểm khác biệt rồi gửi qua Market Researcher giúp anh."),
            ("assistant", "Em tóm 3 điểm:\n\n1. Nhật ký chung thay vì riêng tư\n2. Câu hỏi phản tỉnh có hướng dẫn\n3. Giá thấp hơn nhóm top khoảng 30%\n\nĐã chuyển bản đầy đủ sang Market Researcher."),
            ("user", "Gửi đi nhé, xong thì nhắn anh một tiếng."),
            ("assistant", "ok"),
        ),
    ),
    Bot(
        slug="cho-hong-hot",
        title="chó hóng hớt",
        look=Look(shape="blobatar:hong-hot:organic", color="#f15105"),
        last_message=Recency(days_back=2, clock="08:12"),
        conversation=(
            ("user", "Mỗi sáng 8 giờ gửi anh bản tin AI, tối đa 5 ý, có link nguồn."),
            ("assistant", "Dạ anh. Em đặt lịch 8:00 hằng ngày, 5 ý, kèm link nguồn gốc. Anh muốn thêm mục nào không ạ?"),
            ("user", "Thêm mục cho dev mobile, đừng dài quá."),
            ("assistant", "OK anh, em thêm mục Mobile dev, 1 ý ở cuối bản tin."),
            ("user", "Hôm nay có gì hot không em?"),
            ("assistant", "Anh Anh ơi, đây là bản tin AI hôm nay. Bản tin hôm qua nói về cuộc đua agent, hôm nay có 5 ý:\n\n1. Các hãng lớn tiếp tục mở rộng agent chạy tác vụ dài, xem [Hacker News](https://news.ycombinator.com/)\n2. Chi phí suy luận giảm thêm, nhiều startup hạ giá gói\n3. Mô hình nhỏ chạy trên điện thoại ngày càng tốt\n4. Quy định về dữ liệu huấn luyện được bàn nhiều ở châu Âu\n5. Mobile dev: công cụ code agent tích hợp thẳng vào Xcode"),
        ),
    ),
    Bot(
        slug="market-researcher",
        title="Market Researcher",
        look=Look(shape="blobatar:market:hexagon", color="#833cf8"),
        last_message=Recency(days_back=3, clock="11:40"),
        conversation=(
            ("user", "Chốt cho anh định vị Soully, đừng lan man."),
            ("assistant", "Em đề xuất 2 hướng:\n\n- **Journal-first**: nhật ký là lõi, bạn bè phản hồi\n- **Companion-first**: trợ lý trò chuyện là lõi, nhật ký là phụ\n\nHướng đầu ít đối thủ trực diện hơn."),
            ("user", "Đối thủ chính của hướng đầu là ai?"),
            ("assistant", "Gần nhất là [Day One](https://dayoneapp.com/) và [Reflectly](https://reflectly.app/), nhưng cả hai đều là nhật ký riêng tư. Không bên nào làm nhật ký phản tỉnh chung."),
            ("user", "Chọn hướng journal-first, viết lại one-liner và 3 ý giá trị."),
            ("assistant", "Bản Soully cuối (journal-first, nhật ký phản tỉnh chung):\n\n**One-liner:** Viết nhật ký cùng người thân, hiểu mình hơn mỗi ngày.\n\n- Viết riêng, chia sẻ khi bạn muốn\n- Câu hỏi phản tỉnh gợi ý theo tâm trạng\n- Nhìn lại cả tuần cùng nhau, không cần nói nhiều"),
        ),
    ),
    Bot(
        slug="cho-dinh",
        title="chó Định",
        look=Look(shape="blobatar:dinh:triangle", color="#0ec79b"),
        last_message=Recency(days_back=4, clock="09:25"),
        conversation=(
            ("user", "Định ơi, gộp việc check crash Crashlytics vào routine sáng của em."),
            ("assistant", "Dạ anh Anh. Em đề xuất routine 8:30: kéo tỉ lệ crash-free, liệt kê 3 crash nhiều nhất, gắn link issue tương ứng. Anh đồng ý không ạ?"),
            ("user", "Thêm báo cáo doanh thu RevenueCat nữa, đổ vào Notion."),
            ("assistant", "Em cần API key RevenueCat chỉ đọc. Anh cấp qua biến môi trường giúp em, em không lưu vào chat."),
            ("user", "Cấp rồi. Làm đi."),
            ("assistant", "Xong rồi anh Anh. Em đã gộp vào routine của em và đổ số liệu vào [Notion dashboard](https://www.notion.so/metrics-daily) mỗi sáng 8:30. Lần chạy thử: crash-free 99.4%, doanh thu hôm qua đã khớp với RevenueCat."),
        ),
    ),
)


@dataclass(frozen=True)
class Exchange:
    sender: str
    target: str
    body: str
    reply: str


EXCHANGES = (
    Exchange(
        sender="cho-research-app",
        target="market-researcher",
        body="Final verification for Soully. Plan: /workspace/radar/soully-43b-plan.md (journal-first, cards as optional prompts, pair + receipts). Please:\n\n1. Verify the cited precedents exist and how they're framed (Specula, Hermit's Way, Shadow Work, Arcana).\n2. Check journal-first still lands in a proven payer lane (Stoic, Day One, Reflectly, Rosebud).\n3. Re-score this final version out of 10 with remaining gaps.\n\nWrite /workspace/radar/mr-soully-final.md and message me.",
        reply="Soully final (journal-first): **7.1/10** under the paid-ads-OK bar, a little below Pair's independent 7.3. It's safer at App Review but lands in a thinner lane for revenue.\n\n- Precedents verified: Specula, Hermit's Way and Shadow Work all exist and frame cards as optional prompts\n- Payer lane: Stoic, Day One and Reflectly confirm journal-first still monetises\n- Gaps keeping it below 8:\n  1. Pair mechanic is unproven at scale\n  2. Receipts feel secondary in onboarding\n\nFull report: [mr-soully-final.md](https://www.notion.so/soully-final).",
    ),
    Exchange(
        sender="cho-research-app",
        target="market-researcher",
        body="Thanks. One more check: does removing the oracle-first framing hurt the spiritual payer segment? Add one line to the report.",
        reply="Short answer: a little. Oracle-first converts about 18% better with the spiritual segment, but journal-first keeps App Review risk low. Added one line to the report under Gaps.",
    ),
    Exchange(
        sender="cho-ua",
        target="cho-ai-image-gen",
        body="Brief chốt: 2 bộ, mỗi bộ 6 ảnh. Bộ A pastel sáng, bộ B Giáng sinh tông đậm. Cùng nội dung, chỉ khác hướng thiết kế. Gen xong gửi lại anh duyệt.",
        reply="Đã nhận brief. Em gen 12 ảnh ngay, bản nháp đầu sẽ có sau ít phút.",
    ),
    Exchange(
        sender="cho-ua",
        target="cho-ai-image-gen",
        body="Thêm một ý: ảnh #3 chỉ một cảnh igloo, headline “Find your cozy corner”. Không liệt kê phòng.",
        reply="Ok anh, em cập nhật #3 theo headline mới, không liệt kê phòng.",
    ),
    Exchange(
        sender="default",
        target="cho-ua",
        body="Anh Anh hỏi tiến độ bộ ảnh tháng 12 tới đâu rồi?",
        reply="Đã giao làm 12 ảnh: bộ A pastel sáng, bộ B Giáng sinh tông đậm. Chi tiết xem [bảng creative](https://www.notion.so/creative-ua-t12).",
    ),
)

DM_WAIT_SECONDS = 120

ProviderAccount = namedtuple("ProviderAccount", "provider label auth_type base_path spend")

PROVIDER_ACCOUNTS = (
    ProviderAccount("openai-codex", "Personal", "oauth", "/backend-api/codex", None),
    ProviderAccount("copilot", "Personal", "oauth", "", None),
    ProviderAccount("openai-api", "Default key", "api_key", "", (182_400, 56_300, 4.27)),
)
SPEND_SOURCE = "api_server"

OtherDevice = namedtuple("OtherDevice", "device_id label days_ago")

OTHER_DEVICES = (
    OtherDevice("e2e-desktop-0001", "Bens-MacBook-Pro.local", 9),
    OtherDevice("e2e-desktop-0002", "tsnanh", 56),
)


def slugs():
    return [bot.slug for bot in BOTS]


def message_times(bot, now):
    turns = [as_turn(entry) for entry in bot.conversation]
    times = [bot.last_message.resolve(now)]
    for turn in reversed(turns[1:]):
        gap = turn.gap_before or (REPLY_GAP if turn.role == "assistant" else EXCHANGE_GAP)
        times.append(times[-1] - gap)
    return [moment.timestamp() for moment in reversed(times)]


def profile_directory(home, bot):
    return home if bot.slug == PRIMARY_SLUG else home / "profiles" / bot.slug


def load_gateway_client():
    path = Path(__file__).resolve().parent.parent / "gateway-client" / "gateway_client.py"
    spec = importlib.util.spec_from_file_location("seed_gateway_client", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def bot_meta(bot):
    meta = {"title": bot.title}
    if bot.look is not None:
        meta.update(shape=bot.look.shape, color=bot.look.color, custom=True)
    if bot.pinned:
        meta["pinned"] = True
    return meta


async def configure_bot(rpc, bot):
    result = await rpc.call("profiles.configure", {
        "name": bot.slug,
        "ui_meta": {BOT_META_KEY: bot_meta(bot)},
        "ui_meta_expected_revisions": {BOT_META_KEY: 0},
    })
    if not result.get("applied", {}).get("ui_meta"):
        raise SystemExit(f"profiles.configure rejected ui_meta for {bot.slug}: {json.dumps(result)}")


async def create_bot_chat(rpc, bot):
    created = await rpc.call("session.create", {
        "profile": bot.slug, "title": BOT_CHAT_TITLE, "hidden": True,
        "request_id": str(uuid.uuid4()), "source": SESSION_SOURCE,
    })
    return created["session_id"]


def shared_time(item, now):
    hour, minute = map(int, item.clock.split(":"))
    return (now - timedelta(days=item.days_back)).replace(hour=hour, minute=minute, second=0, microsecond=0).timestamp()


def write_library_media(profile_dir, name):
    from PIL import Image, ImageDraw

    target = profile_dir / "cache" / "images" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGB", (640, 480), (24, 28, 36))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((40, 40, 600, 120), radius=18, fill=(52, 120, 246))
    for row in range(4):
        top = 160 + row * 70
        draw.rounded_rectangle((40, top, 600, top + 50), radius=12, fill=(44, 48, 58))
        draw.ellipse((56, top + 12, 82, top + 38), fill=(245, 138, 6))
    image.save(target, "PNG")
    return target


def write_transcript(profile_dir, session_id, bot, now):
    from hermes_state import SessionDB

    times = message_times(bot, now)
    database = SessionDB(db_path=profile_dir / "state.db")
    try:
        started = times[0]
        for item in bot.shared:
            moment = shared_time(item, now)
            text = item.text
            if item.media:
                text = text.format(media=write_library_media(profile_dir, item.media))
            database.append_message(session_id, item.role, text, timestamp=moment)
            started = min(started, moment)
        for entry, moment in zip(bot.conversation, times, strict=True):
            turn = as_turn(entry)
            database.append_message(session_id, turn.role, turn.text, timestamp=moment, display_kind=turn.display_kind)
        database._write_sql(
            "UPDATE sessions SET started_at = ?, last_activity_at = ? WHERE id = ?",
            (started, times[-1], session_id),
        )
    finally:
        database.close()


def write_dm_replies(path):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({exchange.body.strip(): exchange.reply for exchange in EXCHANGES}, handle, ensure_ascii=False)


async def settled_chat(rpc, slug, session_id, since_messages, reply):
    snapshot = await rpc.call("session.resume", {"profile": slug, "session_id": session_id})
    rows = snapshot.get("messages", [])
    last = rows[-1] if rows else {}
    done = not snapshot.get("running") and len(rows) > since_messages and last.get("role") == "assistant"
    return done and (last.get("text") or last.get("content") or "").strip() == reply.strip()


async def run_exchange(rpc, session_ids, exchange):
    session_id = session_ids[exchange.sender]
    before = len((await rpc.call("session.resume", {"profile": exchange.sender, "session_id": session_id})).get("messages", []))
    await rpc.call("prompt.submit", {
        "profile": exchange.sender, "session_id": session_id, "submission_id": str(uuid.uuid4()),
        "text": f"MESSAGE_AGENT {exchange.target} :: {exchange.body}", "display_kind": "hidden",
    })
    deadline = asyncio.get_running_loop().time() + DM_WAIT_SECONDS
    while not await settled_chat(rpc, exchange.sender, session_id, before, exchange.reply):
        if asyncio.get_running_loop().time() > deadline:
            raise SystemExit(f"bot message {exchange.sender} -> {exchange.target} did not settle in {DM_WAIT_SECONDS}s")
        await asyncio.sleep(0.5)


async def create_routines(rpc, bot):
    for routine in bot.routines:
        result = await rpc.call("cron.manage", {
            "action": "add", "profile": bot.slug, "name": routine.title, "prompt": routine.prompt,
            "schedule": routine.schedule, "deliver": "bot-chat",
        })
        if result.get("success") is False:
            raise SystemExit(f"cron.manage add refused for {bot.slug}: {json.dumps(result)}")


async def seed_through_gateway(home, now):
    client = load_gateway_client()
    environment = os.environ
    gateway = client.Gateway(environment["HERMES_IOS_TEST_BASE_URL"], environment["HERMES_IOS_TEST_USERNAME"],
                             environment["HERMES_IOS_TEST_PASSWORD"])
    url, protocols = gateway.socket_url_and_protocols()
    events = asyncio.Queue()
    async with client.websockets.connect(url, subprotocols=protocols) as socket:
        rpc = client.Rpc(socket, events)
        pump = asyncio.create_task(rpc.pump())
        await events.get()
        session_ids = {}
        for bot in BOTS:
            await configure_bot(rpc, bot)
            session_ids[bot.slug] = await create_bot_chat(rpc, bot)
            write_transcript(profile_directory(home, bot), session_ids[bot.slug], bot, now)
            await create_routines(rpc, bot)
        for exchange in EXCHANGES:
            await run_exchange(rpc, session_ids, exchange)
        pump.cancel()


def provider_root(stub_url):
    return stub_url.rstrip("/").removesuffix("/v1")


def seed_provider_accounts(home, stub_url):
    from hermes_cli.auth import write_credential_pool
    from hermes_state import SessionDB

    root = provider_root(stub_url)
    for account in PROVIDER_ACCOUNTS:
        entry = {
            "id": f"e2e-{account.provider}", "label": account.label, "auth_type": account.auth_type, "priority": 0,
            "source": "manual", "access_token": f"e2e-fake-{account.provider}-credential",
        }
        if account.base_path:
            entry["base_url"] = root + account.base_path
        write_credential_pool(account.provider, [entry])
    database = SessionDB(db_path=home / "state.db")
    try:
        for account in PROVIDER_ACCOUNTS:
            if account.spend is None:
                continue
            input_tokens, output_tokens, usd = account.spend
            database.update_token_counts(
                f"e2e-spend-{account.provider}", input_tokens=input_tokens, output_tokens=output_tokens,
                model="e2e-model", actual_cost_usd=usd, cost_status="actual", cost_source="provider_response",
                billing_provider=account.provider, billing_mode="api", api_call_count=12, source=SPEND_SOURCE)
    finally:
        database.close()


def seed_other_devices(home, now):
    from gateway import device_registry

    root = device_registry.install_root(home)
    for device in OTHER_DEVICES:
        device_registry.record_hello(
            root, device_id=device.device_id, kind="desktop", label=device.label, model="Mac", os_name="macOS",
            app_version="1.0", now=(now - timedelta(days=device.days_ago)).timestamp())


def require_sandbox_home(home):
    resolved = home.resolve()
    if not any(part.startswith(HOME_MARKER) for part in resolved.parts):
        raise SystemExit(f"refusing to seed {resolved}: not an e2e sandbox home")
    if not (resolved / "config.yaml").is_file():
        raise SystemExit(f"refusing to seed {resolved}: no config.yaml")
    for bot in BOTS:
        profile_dir = profile_directory(resolved, bot)
        if not profile_dir.is_dir():
            raise SystemExit(f"profile {bot.slug} missing at {profile_dir}")
    return resolved


def seed(home, repo, dm_replies):
    home = require_sandbox_home(home)
    os.environ["HERMES_HOME"] = str(home)
    write_dm_replies(dm_replies)
    sys.path.insert(0, str(repo))
    now = datetime.now().astimezone()
    asyncio.run(seed_through_gateway(home, now))
    seed_provider_accounts(home, os.environ["HERMES_IOS_E2E_STUB_URL"])
    seed_other_devices(home, now)
    print(",".join(slugs()))


def main():
    parser = argparse.ArgumentParser(description="Seed the parity roster into an e2e sandbox home")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("slugs", help="print the comma separated slugs, primary first")
    seed_parser = commands.add_parser("seed", help="through the running gateway (HERMES_IOS_TEST_* env) write titles and looks, mint each Bot Chat, then write its transcript; profiles must already exist")
    seed_parser.add_argument("--home", required=True, type=Path)
    seed_parser.add_argument("--repo", required=True, type=Path)
    seed_parser.add_argument("--dm-replies", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "slugs":
        print(",".join(slugs()))
    else:
        seed(args.home, args.repo, args.dm_replies)


if __name__ == "__main__":
    main()
