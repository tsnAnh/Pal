import argparse
import asyncio
import importlib.util
import json
import os
import sys
import uuid
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
class Bot:
    slug: str
    title: str
    look: Look | None
    last_message: Recency
    conversation: tuple[tuple[str, str], ...]


BOTS = (
    Bot(
        slug="default",
        title="chó grok bot",
        look=None,
        last_message=Recency(minutes_ago=45),
        conversation=(
            ("user", "Chào em, hôm nay anh cần em gom lại việc của cả đội bot giúp anh."),
            ("assistant", "Dạ anh. Em đang điều phối 7 bot:\n\n- **chó UA** lo creative quảng cáo\n- **chó ai image gen** gen ảnh\n- **Upwork Hunter** săn job\n- **chó research app** nghiên cứu thị trường app\n- **chó hóng hớt** bản tin AI mỗi sáng\n- **Market Researcher** định vị sản phẩm\n- **chó Định** báo cáo số liệu\n\nAnh muốn em hỏi bot nào trước?"),
            ("user", "Hỏi chó UA xem tiến độ bộ ảnh tháng 12 tới đâu rồi."),
            ("assistant", "Em đã nhắn chó UA. Bot trả lời là đã giao làm 12 ảnh, ước tính xong trong 20 phút. Anh xem chi tiết ở [bảng creative](https://www.notion.so/creative-ua-t12) nhé."),
            ("user", "Tốt. Chiều nay nhắc anh duyệt ảnh."),
            ("assistant", "Dạ anh, em đã đặt nhắc lúc 15:00. Có gì thay đổi em báo anh ngay."),
        ),
    ),
    Bot(
        slug="cho-ua",
        title="chó UA",
        look=Look(shape="blobatar:ua:organic", color="#d6264a"),
        last_message=Recency(minutes_ago=12),
        conversation=(
            ("user", "Em ơi, anh cần ảnh banner cho chiến dịch UA tháng 12, test creative cho app học tiếng Anh. Làm được mấy bộ?"),
            ("assistant", "Dạ anh. Em đề xuất 3 hướng creative để test song song:\n\n- **Bộ A**: pastel sáng, mascot cười\n- **Bộ B**: chủ đề Giáng sinh, tông đỏ xanh\n- **Bộ C**: tối giản, chữ lớn, nền trơn\n\nMỗi bộ 4 ảnh, size 1080x1350 cho Meta và 1200x628 cho Google. Anh duyệt hướng trước nhé?"),
            ("user", "OK, làm cả 3 bộ. Nhớ để lại khoảng trống phía dưới cho CTA."),
            ("assistant", "Em ghi nhận: chừa 18% đáy ảnh cho CTA. Em đã gửi yêu cầu sang bot chó ai image gen, anh xem tiến độ ở [bảng creative](https://www.notion.so/creative-ua-t12) nhé."),
            ("user", "Có benchmark CPI của mấy app tương tự không?"),
            ("assistant", "Có anh. Theo [AppMagic](https://appmagic.rocks/) và dữ liệu em tổng hợp được:\n\n- CPI iOS Việt Nam: khoảng $0.8 đến $1.2\n- CPI Android Việt Nam: khoảng $0.3 đến $0.5\n- Creative tối giản thường có CTR cao hơn 15 đến 20%\n\nEm sẽ dùng số này làm mốc cắt creative sau 3 ngày chạy."),
            ("user", "Giao làm luôn đi, xong báo anh."),
            ("assistant", "Đã giao làm 12 ảnh: bộ A pastel sáng, bộ B Giáng sinh, bộ C tối giản. Mỗi bộ 4 ảnh, đúng size Meta và Google, chừa sẵn vùng CTA. Em báo anh ngay khi bot gen ảnh trả file."),
        ),
    ),
    Bot(
        slug="cho-ai-image-gen",
        title="chó ai image gen",
        look=Look(shape="blobatar:ai-image-gen:boxy", color="#ef4444"),
        last_message=Recency(days_back=1, clock="22:48"),
        conversation=(
            ("user", "Gen cho anh logo mascot con chó cầm điện thoại, style flat, nền trong."),
            ("assistant", "Dạ, em đã tạo 4 biến thể logo flat, nền trong suốt:\n\n1. Corgi cầm điện thoại, viền dày\n2. Shiba tông cam\n3. Chó đen tối giản\n4. Chó hoạt hình kiểu sticker\n\nAnh chọn số nào em tinh chỉnh tiếp?"),
            ("user", "Số 2, đổi tông sang xanh mint."),
            ("assistant", "Xong rồi anh, bản mint đây. Em lưu PNG 2048px và SVG trong thư mục chung của đội."),
            ("user", "Em xem tin nhắn từ chó UA đi, có brief mới."),
            ("assistant", "Message from chó UA: Anh CHỐT mới: 6 ảnh mỗi bộ, bỏ bộ C tối giản, giữ bộ A và B. Em sẽ gen lại theo brief này, ước tính 20 phút. Chi tiết xem [brief mới](https://www.notion.so/creative-ua-t12)."),
        ),
    ),
    Bot(
        slug="upwork-hunter",
        title="Upwork Hunter",
        look=Look(shape="blobatar:upwork:round", color="#22c55e"),
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
        look=Look(shape="hexagon", color="#ff2d95"),
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
        look=Look(shape="blobatar:hong-hot:cloud", color="#f97316"),
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
        look=Look(shape="blobatar:market:droplet", color="#9333ea"),
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
        look=Look(shape="blobatar:dinh:capsule", color="#14b8a6"),
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


def slugs():
    return [bot.slug for bot in BOTS]


def message_times(bot, now):
    times = [bot.last_message.resolve(now)]
    for role, _ in reversed(bot.conversation[1:]):
        times.append(times[-1] - (REPLY_GAP if role == "assistant" else EXCHANGE_GAP))
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


def write_transcript(profile_dir, session_id, bot, now):
    from hermes_state import SessionDB

    times = message_times(bot, now)
    database = SessionDB(db_path=profile_dir / "state.db")
    try:
        for (role, text), moment in zip(bot.conversation, times, strict=True):
            database.append_message(session_id, role, text, timestamp=moment)
        database._write_sql(
            "UPDATE sessions SET started_at = ?, last_activity_at = ? WHERE id = ?",
            (times[0], times[-1], session_id),
        )
    finally:
        database.close()


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
        for bot in BOTS:
            await configure_bot(rpc, bot)
            session_id = await create_bot_chat(rpc, bot)
            write_transcript(profile_directory(home, bot), session_id, bot, now)
        pump.cancel()


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


def seed(home, repo):
    home = require_sandbox_home(home)
    os.environ["HERMES_HOME"] = str(home)
    sys.path.insert(0, str(repo))
    asyncio.run(seed_through_gateway(home, datetime.now().astimezone()))
    print(",".join(slugs()))


def main():
    parser = argparse.ArgumentParser(description="Seed the parity roster into an e2e sandbox home")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("slugs", help="print the comma separated slugs, primary first")
    seed_parser = commands.add_parser("seed", help="through the running gateway (HERMES_IOS_TEST_* env) write titles and looks, mint each Bot Chat, then write its transcript; profiles must already exist")
    seed_parser.add_argument("--home", required=True, type=Path)
    seed_parser.add_argument("--repo", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "slugs":
        print(",".join(slugs()))
    else:
        seed(args.home, args.repo)


if __name__ == "__main__":
    main()
