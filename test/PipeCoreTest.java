import top.overdustd7.alttabpipe.KeyPolicy;
import top.overdustd7.alttabpipe.ReleaseSafeQueue;

/** 纯 JVM 测试：不依赖 Android，不需要模拟器。直接跑按键时序与队列满后的释放恢复。 */
public class PipeCoreTest {

    static int pass = 0, fail = 0;

    static void check(String name, boolean ok, String detail) {
        if (ok) { pass++; System.out.println("  ok   " + name); }
        else { fail++; System.out.println("  FAIL " + name + "  -> " + detail); }
    }

    static final int DOWN = KeyPolicy.ACT_DOWN, UP = KeyPolicy.ACT_UP;
    static final int ALT = KeyPolicy.META_ALT_ON, META = KeyPolicy.META_META_ON, SHIFT = KeyPolicy.META_SHIFT_ON;
    static final int TAB = KeyPolicy.KEY_TAB, WIN = KeyPolicy.KEY_META_LEFT;

    static void sequence(String title, KeyPolicy p, int[][] events, int[] expected) {
        System.out.println(title);
        StringBuilder got = new StringBuilder();
        boolean allOk = true;
        for (int i = 0; i < events.length; i++) {
            int r = p.decide(events[i][0], events[i][1], events[i][2], events[i][3]);
            got.append(r);
            if (r != expected[i]) allOk = false;
        }
        check("顺序与判定", allOk, "got=" + got);
    }

    public static void main(String[] args) {
        // ① Win↓ D↓ Win↑ D↑ —— 最后 D↑ 的 meta 已清零，仍必须转发抬起
        sequence("① Win↓ D↓ Win↑ D↑", new KeyPolicy(),
                new int[][]{
                        {WIN, 0, DOWN, 0},          // Win 按下
                        {32, META, DOWN, 0},        // D 按下（Win 按住）
                        {WIN, META, UP, 0},         // Win 抬起
                        {32, 0, UP, 0},             // D 抬起（此时 meta 已清零）
                },
                new int[]{KeyPolicy.KEY_DOWN, KeyPolicy.KEY_DOWN, KeyPolicy.KEY_UP, KeyPolicy.KEY_UP});

        KeyPolicy p2 = new KeyPolicy();
        p2.decide(WIN, 0, DOWN, 0);
        p2.decide(32, META, DOWN, 0);
        int upWin = p2.decide(WIN, META, UP, 0);
        int upD = p2.decide(32, 0, UP, 0);
        check("① Win↑ 后 meta 清零的 D↑ 仍转发", upWin == KeyPolicy.KEY_UP && upD == KeyPolicy.KEY_UP,
                "upWin=" + upWin + " upD=" + upD);

        // ② Alt↓ Tab↓ Alt↑ Tab↑ —— 先吞了 Tab↓，Tab↑ 不能泄漏
        KeyPolicy p3 = new KeyPolicy();
        int a1 = p3.decide(57, 0, DOWN, 0);
        int t1 = p3.decide(TAB, ALT, DOWN, 0);
        int a2 = p3.decide(57, ALT, UP, 0);
        int t2 = p3.decide(TAB, 0, UP, 0);
        check("② Alt↓ Tab↓ Alt↑ Tab↑",
                a1 == KeyPolicy.PASS && t1 == KeyPolicy.ALT_TAB
                        && a2 == KeyPolicy.PASS && t2 == KeyPolicy.ALT_TAB_UP,
                "a1=" + a1 + " t1=" + t1 + " a2=" + a2 + " t2=" + t2);

        // ③ 自动重复：接管的键重复按下仍吞掉，不重复转发
        KeyPolicy p4 = new KeyPolicy();
        p4.decide(WIN, 0, DOWN, 0);
        p4.decide(32, META, DOWN, 0);
        int rep = p4.decide(32, META, DOWN, 3);
        check("③ 自动重复不重复转发", rep == KeyPolicy.SWALLOW, "rep=" + rep);

        // ④ 未接管的普通字符一律放行
        KeyPolicy p5 = new KeyPolicy();
        int n1 = p5.decide(30, 0, DOWN, 0);
        int n2 = p5.decide(30, 0, UP, 0);
        check("④ 普通字符放行", n1 == KeyPolicy.PASS && n2 == KeyPolicy.PASS, n1 + "," + n2);

        // ⑤ 归属计数（退出时据此决定要不要补发释放）
        KeyPolicy p6 = new KeyPolicy();
        p6.decide(WIN, 0, DOWN, 0);
        p6.decide(32, META, DOWN, 0);
        boolean two = p6.ownedCount() == 2;
        p6.decide(WIN, META, UP, 0);
        p6.decide(32, 0, UP, 0);
        check("⑤ 归属计数", two && p6.ownedCount() == 0, "owned=" + p6.ownedCount());

        // ⑥ 队列满：关键报文换成补发标记，普通报文只丢不说
        System.out.println("⑥ 队列满时的释放恢复");
        ReleaseSafeQueue q = new ReleaseSafeQueue(4);
        for (int i = 0; i < 4; i++) q.offer(("K" + i).getBytes(), false);
        boolean criticalOk = q.offer("KEY 32 0".getBytes(), true);
        boolean plainOk = q.offer("KEY 30 1".getBytes(), false);
        check("关键报文入队失败并置补发标记",
                !criticalOk && q.hasResync(), "criticalOk=" + criticalOk + " resync=" + q.hasResync());
        check("普通报文满时只丢不置标记", !plainOk && q.drops() == 2, "drops=" + q.drops());
        // 排空后再取标记：补发必须排在已入队报文之后
        int drained = 0;
        try {
            while (!q.isEmpty()) { q.poll(0); drained++; }
        } catch (InterruptedException ignored) {
        }
        boolean resync = q.takeResync();
        check("排空后取出补发标记", drained == 4 && resync && !q.hasResync(),
                "drained=" + drained + " resync=" + resync);

        System.out.println();
        System.out.println("pass=" + pass + " fail=" + fail);
        if (fail > 0) System.exit(1);
    }
}
