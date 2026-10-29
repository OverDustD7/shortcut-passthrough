package top.overdustd7.alttabpipe;

/**
 * 按键归属判定（纯 Java，不依赖 Android，可在 JVM 上直接测）。
 *
 * 解决的问题：抬起事件不能靠"当前修饰位"判断，否则
 *   Win↓ D↓ Win↑ D↑ —— 最后的 D↑ 的 meta 已经清零，就被漏掉了；
 *   Alt↓ Tab↓ Alt↑ Tab↑ —— 先吞了 Tab↓，后面 Tab↑ 泄漏给系统。
 * 做法：记住本应用真正吞下过哪些键，抬起只看归属。
 */
public final class KeyPolicy {

    public static final int PASS = 0;          // 原样交给系统
    public static final int SWALLOW = 1;       // 吞掉，不发任何报文
    public static final int KEY_DOWN = 2;      // 吞掉并转发按下
    public static final int KEY_UP = 3;        // 吞掉并转发抬起
    public static final int ALT_TAB = 4;       // 吞掉并发 ALT_TAB
    public static final int ALT_TAB_REV = 5;   // 吞掉并发 ALT_TAB_REV
    public static final int ALT_TAB_UP = 6;    // 吞掉（Alt+Tab 的抬起，配对用）

    public static final int ACT_DOWN = 0;
    public static final int ACT_UP = 1;

    public static final int META_SHIFT_ON = 0x1;
    public static final int META_ALT_ON = 0x2;
    public static final int META_CTRL_ON = 0x1000;
    public static final int META_META_ON = 0x10000;

    public static final int KEY_TAB = 61;
    public static final int KEY_META_LEFT = 117;
    public static final int KEY_META_RIGHT = 118;

    private final java.util.HashSet<Integer> ownedKeys = new java.util.HashSet<Integer>();
    private final java.util.HashSet<Integer> ownedAltTab = new java.util.HashSet<Integer>();

    /**
     * @param code        Android keyCode
     * @param meta        KeyEvent.getMetaState()
     * @param action      ACTION_DOWN / ACTION_UP
     * @param repeatCount KeyEvent.getRepeatCount()
     */
    public int decide(int code, int meta, int action, int repeatCount) {
        if (action == ACT_DOWN) {
            if (repeatCount > 0) {
                // 自动重复：本应用接管过的键继续吞掉。主机侧那个键一直按着，
                // Windows 会自己产生重复，所以本地不必重复转发。
                if (ownedKeys.contains(code) || ownedAltTab.contains(code)) return SWALLOW;
                return PASS;
            }
            if (isMetaKey(code) || metaHeld(meta)) {
                ownedKeys.add(code);
                return KEY_DOWN;
            }
            if (isPlainAltTab(code, meta)) {
                ownedAltTab.add(code);
                return (meta & META_SHIFT_ON) != 0 ? ALT_TAB_REV : ALT_TAB;
            }
            return PASS;
        }

        // 抬起：先看归属，与当前修饰位无关
        if (ownedKeys.remove(code)) return KEY_UP;
        if (ownedAltTab.remove(code)) return ALT_TAB_UP;

        // 兜底：服务中途重启会丢掉归属记录。这时若修饰位仍表明是我们的组合键，
        // 就把抬起也吞掉并转发，宁可多发一个"抬起"（主机侧是无害的），不留下卡键。
        if (isMetaKey(code) || metaHeld(meta)) return KEY_UP;
        if (isPlainAltTab(code, meta)) return ALT_TAB_UP;
        return PASS;
    }

    /** 主机侧需要释放的键数（用于退出时决定要不要发 RELEASE_ALL） */
    public int ownedCount() {
        return ownedKeys.size() + ownedAltTab.size();
    }

    public void reset() {
        ownedKeys.clear();
        ownedAltTab.clear();
    }

    private static boolean isMetaKey(int code) {
        return code == KEY_META_LEFT || code == KEY_META_RIGHT;
    }

    private static boolean metaHeld(int meta) {
        return (meta & META_META_ON) != 0;
    }

    private static boolean isPlainAltTab(int code, int meta) {
        return code == KEY_TAB
                && (meta & META_ALT_ON) != 0
                && (meta & (META_CTRL_ON | META_META_ON)) == 0;
    }
}
