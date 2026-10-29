package top.overdustd7.alttabpipe;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * 发送队列（纯 Java，可在 JVM 上测）。
 *
 * UDP 本身会丢包，这里能保证的只有：**本地的发送顺序**，以及队列满时
 * 关键报文（按键抬起、释放全部）不会静默消失——它们会换成一个"稍后补一条
 * RELEASE_ALL"的标记，由发送线程在队列排空后补发。主机侧另有 8 秒卡键超时兜底。
 *
 * 顺序约定：补发的 RELEASE_ALL 一定排在已入队报文之后，不会插到前面去。
 */
public final class ReleaseSafeQueue {

    private final ArrayBlockingQueue<byte[]> q;
    private volatile boolean resyncNeeded = false;
    private volatile int drops = 0;

    public ReleaseSafeQueue(int capacity) {
        if (capacity <= 0) throw new IllegalArgumentException("capacity must be > 0");
        q = new ArrayBlockingQueue<byte[]>(capacity);
    }

    /**
     * @param critical true 表示这条报文承载"松开某个键"的语义，丢了会让主机卡键
     * @return true 表示已入队
     */
    public boolean offer(byte[] payload, boolean critical) {
        if (payload == null) return false;
        if (q.offer(payload)) return true;
        drops++;
        // 队列满：普通报文丢了就丢了；关键报文换成一个补发标记
        if (critical) resyncNeeded = true;
        return false;
    }

    /** 发送线程在队列排空后调用：是否需要补一条 RELEASE_ALL */
    public boolean takeResync() {
        if (!resyncNeeded) return false;
        resyncNeeded = false;
        return true;
    }

    public boolean hasResync() {
        return resyncNeeded;
    }

    public byte[] poll(int ms) throws InterruptedException {
        return q.poll(ms, TimeUnit.MILLISECONDS);
    }

    public byte[] take() throws InterruptedException {
        return q.take();
    }

    public boolean isEmpty() {
        return q.isEmpty();
    }

    public int size() {
        return q.size();
    }

    public int drops() {
        return drops;
    }
}
