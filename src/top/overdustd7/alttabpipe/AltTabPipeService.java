package top.overdustd7.alttabpipe;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.os.Build;
import android.os.Handler;
import android.os.SystemClock;
import android.util.Log;
import android.view.KeyEvent;
import android.view.accessibility.AccessibilityEvent;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;

/**
 * 把 Alt+Tab 与带 Win 的组合键转给主机。
 *
 * 约束（v1.4 起）：
 *   1. 只在目标应用前台时才申请按键过滤；其余时候系统不走这一趟，普通打字零影响。
 *   2. 回调里只做整数判断与入队（KeyPolicy / ReleaseSafeQueue 都是纯 Java，可在 JVM 上测）。
 *   3. 抬起按"本应用吞过哪些键"判定，不依赖当前修饰位。
 *   4. 队列满时关键报文（抬起、释放）换成一个补发 RELEASE_ALL 的标记，退出时也会补发。
 *   5. 本地只保证发送顺序；丢了只由主机侧 8 秒卡键超时兜底。
 */
public class AltTabPipeService extends AccessibilityService {

    private static final String TAG = "AltTabPipe";
    public static final String PREFS = "cfg";
    public static final int DEFAULT_PORT = 47823;
    public static final String DEFAULT_TARGETS = "com.limelight";
    /** 明确要求接管一切（会拖慢所有应用的打字），必须用户自己填 */
    public static final String GLOBAL_TARGET = "*";

    // ---- 诊断计数（界面读取；热路径只写 int/long，不分配对象）
    public static volatile long connectedAt = 0;
    public static volatile int keyCount = 0;
    public static volatile int sentCount = 0;
    public static volatile int failCount = 0;
    public static volatile int dropCount = 0;
    public static volatile int resyncCount = 0;
    public static volatile long cbMaxUs = 0;
    public static volatile long cbLastUs = 0;
    public static volatile long lagMaxMs = 0;
    public static volatile boolean filterOn = false;
    public static volatile int lastCode = -1;
    public static volatile int lastMeta = 0;
    public static volatile int lastAct = -1;
    public static volatile long lastKeyAt = 0;
    public static volatile String foregroundPkg = "";
    public static volatile boolean foreground = false;
    /** 上次服务被解绑的时刻，用来区分「已启用」和「真的绑着」 */
    public static volatile long lastUnbindAt = 0;
    public static volatile AltTabPipeService instance = null;

    private static final String CHANNEL = "pipe";
    private static final int QUEUE_CAP = 512;
    private static final int DRAIN_WAIT_MS = 300;

    private static final byte[] P_ALT_TAB = "ALT_TAB".getBytes();
    private static final byte[] P_ALT_TAB_REV = "ALT_TAB_REV".getBytes();
    private static final byte[] P_RELEASE_ALL = "RELEASE_ALL".getBytes();

    private final KeyPolicy policy = new KeyPolicy();
    private final ReleaseSafeQueue queue = new ReleaseSafeQueue(QUEUE_CAP);

    private Thread worker;
    private volatile boolean running = false;
    private volatile boolean shuttingDown = false;

    private volatile String host = "";
    private volatile int port = DEFAULT_PORT;
    private volatile String targetSpec = DEFAULT_TARGETS;
    private volatile String[] targets = new String[]{DEFAULT_TARGETS};

    /** 最近经过的前台应用（从新到旧），用于诊断"为什么没接管" */
    public static volatile String fgHistory = "";
    private Handler guard;
    private final Runnable guardTask = new Runnable() {
        @Override
        public void run() {
            // 过滤没开时才自检；开了就靠窗口事件，别白花 binder
            if (!filterOn) refreshForeground();
            if (guard != null) guard.postDelayed(this, 3000);
        }
    };

    // 发送线程独占
    private DatagramSocket socket;
    private InetAddress addr;
    private long lastResolveAt = 0;

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        instance = this;
        connectedAt = SystemClock.elapsedRealtime();
        reloadConfig();
        ensureForeground();
        startWorker();
        // 关键：先按当前真实窗口状态判定一次。如果开无障碍时目标应用已经在前台，
        // 之后不会再有窗口切换事件，光等事件会让过滤永远不开（表现就是"没效果"）。
        refreshForeground();
        applyFilter(hitTarget(foregroundPkg));
        startGuard();
        Log.i(TAG, "connected, targets=" + targetSpec + " fg=" + foregroundPkg + " filter=" + filterOn);
    }

    @Override
    public boolean onUnbind(android.content.Intent intent) {
        shutdown("unbind");
        return super.onUnbind(intent);
    }

    @Override
    public void onDestroy() {
        shutdown("destroy");
        super.onDestroy();
    }

    /**
     * 退出时的释放策略：先排空队列把已有的报文发完（最多等 300 ms），
     * 再用缓存的地址直接补一条 RELEASE_ALL；不解析域名，不会无限等待。
     */
    private void shutdown(String why) {
        if (shuttingDown) return;
        shuttingDown = true;
        if (instance == this) instance = null;
        if (guard != null) {
            guard.removeCallbacks(guardTask);
            guard = null;
        }
        if ("unbind".equals(why)) lastUnbindAt = SystemClock.elapsedRealtime();
        Log.i(TAG, "shutdown(" + why + ") owned=" + policy.ownedCount());

        boolean needRelease = policy.ownedCount() > 0 || queue.hasResync();
        if (needRelease) queue.offer(P_RELEASE_ALL, true);

        running = false;
        if (worker != null) {
            try {
                worker.join(DRAIN_WAIT_MS);
            } catch (InterruptedException ignored) {
            }
            worker.interrupt();
        }
        // 兜底：队列没排空也补一条（只用缓存地址，不做 DNS）
        if (needRelease) sendDirect(P_RELEASE_ALL);

        policy.reset();
        closeSocket();
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // 不直接采信事件里的包名：通知、输入法、系统对话框也会发窗口事件，
        // 照它开关过滤会让过滤莫名被关掉，而真实前台没变就不会再开回来。
        // 事件只当提醒，前台一律以 TYPE_APPLICATION 窗口为准。
        refreshForeground();
    }

    /** 一键自检：重新读前台、重算过滤，返回一行结果 */
    public String selfCheck() {
        reloadConfig();
        refreshForeground();
        applyFilter(hitTarget(foregroundPkg));
        return "fg=" + foregroundPkg + "  filter=" + filterOn + "  targets=" + targetSpec;
    }
    /** 前台应用变化时的唯一入口：记录、记历史、按需开关过滤 */
    private void noteForeground(String pkg) {
        if (pkg == null || pkg.length() == 0) return;
        if (pkg.equals(foregroundPkg)) return;
        foregroundPkg = pkg;
        pushHistory(pkg);
        boolean want = hitTarget(pkg);
        if (want != filterOn) applyFilter(want);
    }

    private void pushHistory(String pkg) {
        String h = fgHistory;
        if (h.startsWith(pkg + " |")) return;
        h = pkg + " | " + h;
        if (h.length() > 180) h = h.substring(0, 180);
        fgHistory = h;
    }

    private void startGuard() {
        if (guard != null) return;
        guard = new Handler(android.os.Looper.getMainLooper());
        guard.postDelayed(guardTask, 3000);
    }

    /**
     * 用 getWindows() 直接读当前前台窗口的包名。
     * 只读包名，不读界面内容。
     */
    private void refreshForeground() {
        try {
            // 首选：活动窗口的根节点包名（不依赖 flagRetrieveInteractiveWindows）
            android.view.accessibility.AccessibilityNodeInfo act = getRootInActiveWindow();
            if (act != null) {
                CharSequence ap = act.getPackageName();
                if (ap != null && ap.length() > 0) {
                    noteForeground(ap.toString());
                    return;
                }
            }
        } catch (Throwable t) {
            Log.w(TAG, "getRootInActiveWindow failed: " + t);
        }
        try {
            java.util.List<android.view.accessibility.AccessibilityWindowInfo> ws = getWindows();
            if (ws == null || ws.isEmpty()) return;
            String focused = null, any = null;
            for (android.view.accessibility.AccessibilityWindowInfo w : ws) {
                if (w == null) continue;
                if (w.getType() != android.view.accessibility.AccessibilityWindowInfo.TYPE_APPLICATION) continue;
                CharSequence p = null;
                try {
                    if (w.getRoot() != null) p = w.getRoot().getPackageName();
                } catch (Throwable ignored) {
                }
                if (p == null) continue;
                if (any == null) any = p.toString();
                if (w.isFocused()) {
                    focused = p.toString();
                    break;
                }
            }
            String best = focused != null ? focused : any;
            if (best != null) noteForeground(best);
        } catch (Throwable t) {
            Log.w(TAG, "refreshForeground failed: " + t);
        }
    }

    @Override
    public void onInterrupt() {
    }

    @Override
    public boolean onKeyEvent(KeyEvent event) {
        final long t0 = System.nanoTime();
        try {
            final int code = event.getKeyCode();
            final int meta = event.getMetaState();
            final int act = event.getAction();
            final int rep = event.getRepeatCount();
            final int what = policy.decide(code, meta, act, rep);

            keyCount++;
            lastCode = code;
            lastMeta = meta;
            lastAct = act;
            lastKeyAt = SystemClock.elapsedRealtime();
            long lag = SystemClock.uptimeMillis() - event.getEventTime();
            if (lag > lagMaxMs) lagMaxMs = lag;

            switch (what) {
                case KeyPolicy.KEY_DOWN:
                    queue.offer(keyPayload(code, true), false);
                    return true;
                case KeyPolicy.KEY_UP:
                    // 抬起是关键报文：丢了会让主机卡键
                    queue.offer(keyPayload(code, false), true);
                    return true;
                case KeyPolicy.ALT_TAB:
                    queue.offer(P_ALT_TAB, false);
                    return true;
                case KeyPolicy.ALT_TAB_REV:
                    queue.offer(P_ALT_TAB_REV, false);
                    return true;
                case KeyPolicy.ALT_TAB_UP:
                    return true;
                case KeyPolicy.SWALLOW:
                    return true;
                default:
                    return false;
            }
        } finally {
            long us = (System.nanoTime() - t0) / 1000;
            cbLastUs = us;
            if (us > cbMaxUs) cbMaxUs = us;
            if ((keyCount % 30) == 0) {
                Log.i(TAG, "keys=" + keyCount + " cbMaxUs=" + cbMaxUs + " lagMaxMs=" + lagMaxMs
                        + " sent=" + sentCount + " fail=" + failCount
                        + " drop=" + queue.drops() + " resync=" + resyncCount);
            }
        }
    }

    // ---------- 过滤开关 ----------

    private void applyFilter(boolean on) {
        try {
            AccessibilityServiceInfo info = getServiceInfo();
            if (info == null) return;
            int want = AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS;
            boolean has = (info.flags & want) != 0;
            if (has == on) {
                filterOn = on;
                return;
            }
            info.flags = on ? (info.flags | want) : (info.flags & ~want);
            setServiceInfo(info);
            filterOn = on;
            if (!on) {
                queue.offer(P_RELEASE_ALL, true);
                policy.reset();
            }
            Log.i(TAG, "filter=" + on + " (fg=" + foregroundPkg + ")");
        } catch (Throwable t) {
            Log.w(TAG, "applyFilter failed: " + t);
        }
    }

    /**
     * 安全默认：配置为空、只剩空项、或不匹配时一律**不接管**。
     * 想要全局接管必须在配置里明确写 "*"。
     */
    private boolean hitTarget(String pkg) {
        String[] t = targets;
        if (t == null || t.length == 0) return false;
        if (pkg == null) return false;
        for (String raw : t) {
            if (raw == null) continue;
            String s = raw.trim();
            if (s.length() == 0) continue;
            if (GLOBAL_TARGET.equals(s)) return true;
            if (pkg.startsWith(s)) return true;
        }
        return false;
    }

    // ---------- 发送 ----------

    private static byte[] keyPayload(int code, boolean down) {
        return ("KEY " + code + " " + (down ? "1" : "0")).getBytes();
    }

    private void startWorker() {
        running = true;
        worker = new Thread(new Runnable() {
            @Override
            public void run() {
                while (running || !queue.isEmpty()) {
                    byte[] p = null;
                    try {
                        p = queue.poll(150);
                    } catch (InterruptedException e) {
                        break;
                    }
                    if (p != null) {
                        sendNow(p);
                        continue;
                    }
                    // 队列排空后才补发释放，保证它排在已入队报文之后
                    if (queue.takeResync()) {
                        resyncCount++;
                        Log.i(TAG, "resync: 补发 RELEASE_ALL");
                        sendNow(P_RELEASE_ALL);
                    }
                }
                if (queue.takeResync()) {
                    resyncCount++;
                    sendNow(P_RELEASE_ALL);
                }
            }
        }, "alttab-sender");
        worker.setDaemon(true);
        worker.start();
    }

    private void sendNow(byte[] payload) {
        try {
            if (shuttingDown && addr == null) {
                // 退出阶段不解析域名，避免拖住
                return;
            }
            if (socket == null || socket.isClosed()) {
                socket = new DatagramSocket();
            }
            InetAddress a = resolve(false);
            if (a == null) {
                failCount++;
                return;
            }
            socket.send(new DatagramPacket(payload, payload.length, a, port));
            sentCount++;
        } catch (Throwable t) {
            failCount++;
            closeSocket();
        }
    }

    /** 退出兜底：只用已缓存的地址，不做 DNS、不阻塞 */
    private void sendDirect(byte[] payload) {
        try {
            if (addr == null) return;
            if (socket == null || socket.isClosed()) socket = new DatagramSocket();
            socket.send(new DatagramPacket(payload, payload.length, addr, port));
            sentCount++;
        } catch (Throwable ignored) {
        }
    }

    private InetAddress resolve(boolean force) {
        if (addr != null && !force) return addr;
        long now = SystemClock.elapsedRealtime();
        if (!force && now - lastResolveAt < 5000) return null;
        lastResolveAt = now;
        try {
            addr = InetAddress.getByName(host);
            return addr;
        } catch (Throwable t) {
            addr = null;
            return null;
        }
    }

    private void closeSocket() {
        try {
            if (socket != null) socket.close();
        } catch (Throwable ignored) {
        }
        socket = null;
    }

    // ---------- 配置 ----------

    public void reloadConfig() {
        android.content.SharedPreferences p = getSharedPreferences(PREFS, MODE_PRIVATE);
        applyConfig(p.getString("host", ""),
                p.getInt("port", DEFAULT_PORT),
                p.getString("targets", DEFAULT_TARGETS));
    }

    void applyConfig(String hostV, int portV, String targetSpecV) {
        host = hostV == null ? "" : hostV;
        port = portV > 0 ? portV : DEFAULT_PORT;
        targetSpec = targetSpecV == null ? "" : targetSpecV;
        String[] parts = targetSpec.split(",");
        java.util.ArrayList<String> keep = new java.util.ArrayList<String>();
        for (String p : parts) {
            if (p == null) continue;
            String s = p.trim();
            if (s.length() > 0) keep.add(s);
        }
        targets = keep.toArray(new String[0]);
        addr = null;
        lastResolveAt = 0;
        dropCount = queue.drops();
    }

    /** 把进程钉成前台，降低被系统降权的机会 */
    private void ensureForeground() {
        try {
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (Build.VERSION.SDK_INT >= 26) {
                NotificationChannel ch = new NotificationChannel(CHANNEL, "按键转发", NotificationManager.IMPORTANCE_MIN);
                ch.setShowBadge(false);
                nm.createNotificationChannel(ch);
            }
            Notification n = new Notification.Builder(this, CHANNEL)
                    .setContentTitle("快捷键直通运行中")
                    .setContentText("仅在目标应用前台时接管 Alt+Tab 与 Win 组合键")
                    .setSmallIcon(android.R.drawable.ic_menu_send)
                    .setOngoing(true)
                    .build();
            startForeground(1, n);
            foreground = true;
        } catch (Throwable t) {
            foreground = false;
            Log.w(TAG, "startForeground failed: " + t);
        }
    }
}
