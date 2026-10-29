package top.overdustd7.alttabpipe;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;

public class MainActivity extends Activity {

    private EditText hostBox;
    private EditText portBox;
    private EditText targetsBox;
    private TextView status;
    private SharedPreferences prefs;
    private Handler poller;
    private final Runnable pollTask = new Runnable() {
        @Override
        public void run() {
            refresh();
            if (poller != null) poller.postDelayed(this, 500);
        }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = getSharedPreferences(AltTabPipeService.PREFS, MODE_PRIVATE);

        // 允许用 adb / 快捷方式直接带入配置：am start ... --es host <ip> --ei port <n>
        applyIntentConfig(getIntent(), true);

        float d = getResources().getDisplayMetrics().density;
        int pad = (int) (18 * d);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);

        root.addView(label("主机地址（IPv6 或 IPv4，只填地址不要带端口）"));
        hostBox = new EditText(this);
        hostBox.setSingleLine(true);
        hostBox.setInputType(InputType.TYPE_CLASS_TEXT);
        hostBox.setText(prefs.getString("host", ""));
        hostBox.setHint("例如 fe80::1234:5678:9abc:def0");
        root.addView(hostBox);

        root.addView(label("端口"));
        portBox = new EditText(this);
        portBox.setSingleLine(true);
        portBox.setInputType(InputType.TYPE_CLASS_NUMBER);
        portBox.setText(String.valueOf(prefs.getInt("port", AltTabPipeService.DEFAULT_PORT)));
        root.addView(portBox);

        root.addView(label("接管名单（包名前缀，逗号分隔。留空=不接管；填 * = 接管所有应用，会拖慢打字）"));
        targetsBox = new EditText(this);
        targetsBox.setSingleLine(true);
        targetsBox.setInputType(InputType.TYPE_CLASS_TEXT);
        targetsBox.setText(prefs.getString("targets", AltTabPipeService.DEFAULT_TARGETS));
        targetsBox.setHint("com.limelight");
        root.addView(targetsBox);

        Button save = new Button(this);
        save.setText("保存");
        save.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                saveCfg();
                Toast.makeText(MainActivity.this, "已保存", Toast.LENGTH_SHORT).show();
                refresh();
            }
        });
        root.addView(save);

        Button test = new Button(this);
        test.setText("发送一次测试包");
        test.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                saveCfg();
                send("PING");
            }
        });
        root.addView(test);

        Button a11y = new Button(this);
        a11y.setText("打开无障碍设置");
        a11y.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS));
                } catch (Exception e) {
                    Toast.makeText(MainActivity.this, "打不开设置：" + e, Toast.LENGTH_LONG).show();
                }
            }
        });
        root.addView(a11y);

        Button check = new Button(this);
        check.setText("一键自检（读前台、重算过滤）");
        check.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                AltTabPipeService s = AltTabPipeService.instance;
                String r = (s == null) ? "服务实例不在：无障碍没有真正绑上，去设置里关一次再开" : s.selfCheck();
                Toast.makeText(MainActivity.this, r, Toast.LENGTH_LONG).show();
                refresh();
            }
        });
        root.addView(check);
        Button batt = new Button(this);
        batt.setText("① 电池：设为不受限制");
        batt.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                askBatteryExempt();
            }
        });
        root.addView(batt);

        Button auto = new Button(this);
        auto.setText("② 小米自启动设置");
        auto.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                openAutostart();
            }
        });
        root.addView(auto);

        Button notif = new Button(this);
        notif.setText("③ 允许通知（常驻通知要靠它）");
        notif.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                askNotifications();
            }
        });
        root.addView(notif);

        Button lock = new Button(this);
        lock.setText("④ 最近任务里把本应用下拉锁定（这个只能手动）");
        lock.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Toast.makeText(MainActivity.this,
                        "打开最近任务，把「AltTab 直通」那张卡片下拉锁定，别划掉它",
                        Toast.LENGTH_LONG).show();
            }
        });
        root.addView(lock);

        status = new TextView(this);
        status.setPadding(0, pad, 0, 0);
        root.addView(status);

        ScrollView sv = new ScrollView(this);
        sv.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        setContentView(sv);
        refresh();
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
        poller = new Handler(Looper.getMainLooper());
        poller.postDelayed(pollTask, 500);
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (poller != null) {
            poller.removeCallbacks(pollTask);
            poller = null;
        }
    }

    private TextView label(String s) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setPadding(0, (int) (10 * getResources().getDisplayMetrics().density), 0, 0);
        return t;
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (applyIntentConfig(intent, false)) refresh();
    }

    /** 从启动参数里取配置；返回是否改动过。force=true 时连 host 为空也写入 */
    private boolean applyIntentConfig(Intent intent, boolean force) {
        if (intent == null) return false;
        String ih = intent.getStringExtra("host");
        int ip = intent.getIntExtra("port", -1);
        String it = intent.getStringExtra("targets");
        if (ih == null && ip <= 0 && it == null) return false;
        SharedPreferences.Editor ed = prefs.edit();
        if (ih != null) ed.putString("host", ih.trim());
        if (ip > 0) ed.putInt("port", ip);
        if (it != null) ed.putString("targets", it.trim());
        ed.apply();
        AltTabPipeService s = AltTabPipeService.instance;
        if (s != null) s.reloadConfig();
        return true;
    }

    private void saveCfg() {
        SharedPreferences.Editor e = prefs.edit();
        e.putString("host", hostBox.getText().toString().trim());
        int port = AltTabPipeService.DEFAULT_PORT;
        try {
            port = Integer.parseInt(portBox.getText().toString().trim());
        } catch (Exception ignored) {
        }
        e.putInt("port", port);
        e.putString("targets", targetsBox.getText().toString().trim());
        e.apply();
        AltTabPipeService s = AltTabPipeService.instance;
        if (s != null) s.reloadConfig();
    }

    private boolean a11yEnabled() {
        String flat = Settings.Secure.getString(getContentResolver(),
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (flat == null) return false;
        ComponentName me = new ComponentName(this, AltTabPipeService.class);
        return flat.contains(me.flattenToString()) || flat.contains(me.flattenToShortString());
    }

    private boolean batteryExempt() {
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        return pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());
    }

    private void askBatteryExempt() {
        try {
            if (batteryExempt()) {
                Toast.makeText(this, "已经是「不受限制」", Toast.LENGTH_SHORT).show();
                return;
            }
            startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:" + getPackageName())));
        } catch (Exception e) {
            try {
                startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
            } catch (Exception e2) {
                Toast.makeText(this, "打不开电池设置：" + e2, Toast.LENGTH_LONG).show();
            }
        }
    }

    private void openAutostart() {
        String[][] targets = new String[][]{
                {"com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"},
                {"com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"}
        };
        for (String[] t : targets) {
            try {
                Intent i = new Intent();
                i.setComponent(new ComponentName(t[0], t[1]));
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(i);
                return;
            } catch (Exception ignored) {
            }
        }
        try {
            startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + getPackageName())));
            Toast.makeText(this, "没找到自启动页，已打开本应用详情，请在里面找「自启动」",
                    Toast.LENGTH_LONG).show();
        } catch (Exception e) {
            Toast.makeText(this, "打不开：" + e, Toast.LENGTH_LONG).show();
        }
    }

    private void askNotifications() {
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission("android.permission.POST_NOTIFICATIONS") != 0) {
            requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"}, 1);
            return;
        }
        Toast.makeText(this, "通知权限已允许", Toast.LENGTH_SHORT).show();
    }

    private void refresh() {
        long now = android.os.SystemClock.elapsedRealtime();
        StringBuilder sb = new StringBuilder();
        sb.append("无障碍服务：").append(a11yEnabled() ? "已开启" : "未开启（必须开启才会生效）").append("\n");
        if (AltTabPipeService.connectedAt > 0) {
            long up = (now - AltTabPipeService.connectedAt) / 1000;
            sb.append("服务已运行：").append(up / 60).append(" 分 ").append(up % 60).append(" 秒\n");
        } else {
            sb.append("服务已运行：（本次开机后还没连上）\n");
        }
        sb.append("服务实例：").append(AltTabPipeService.instance != null ? "已连接（真正绑着）" : "未连接（只是设置里显示已开启）").append("\n");
        if (AltTabPipeService.lastUnbindAt > 0) {
            sb.append("上次断开：").append((now - AltTabPipeService.lastUnbindAt) / 1000).append(" 秒前\n");
        }
        sb.append("按键过滤：").append(AltTabPipeService.filterOn ? "开启（当前应用在接管名单里）" : "关闭（正常打字不走本应用）").append("\n");
        sb.append("当前前台：").append(AltTabPipeService.foregroundPkg.length() == 0 ? "（未知）" : AltTabPipeService.foregroundPkg).append("\n");
        if (AltTabPipeService.fgHistory.length() > 0) {
            sb.append("最近经过：").append(AltTabPipeService.fgHistory).append("\n");
        }
        sb.append("过滤回调：次数 ").append(AltTabPipeService.keyCount)
          .append("　最长 ").append(AltTabPipeService.cbMaxUs).append(" 微秒")
          .append("　排队最长 ").append(AltTabPipeService.lagMaxMs).append(" 毫秒\n");
        sb.append("报文：已发 ").append(AltTabPipeService.sentCount)
          .append("　失败 ").append(AltTabPipeService.failCount)
          .append("　丢队列 ").append(AltTabPipeService.dropCount)
          .append("　补发释放 ").append(AltTabPipeService.resyncCount).append("\n");
        if (AltTabPipeService.lastKeyAt > 0) {
            long ago = (now - AltTabPipeService.lastKeyAt) / 1000;
            sb.append("最后一个键：code=").append(AltTabPipeService.lastCode)
              .append(" meta=").append(AltTabPipeService.lastMeta)
              .append(" act=").append(AltTabPipeService.lastAct)
              .append("（").append(ago).append(" 秒前）\n");
        } else {
            sb.append("最后一个键：（还没有按键经过）\n");
        }
        sb.append("保护状态：电池 ").append(batteryExempt() ? "不受限制" : "受限制（点 ①）")
          .append("　常驻前台 ").append(AltTabPipeService.foreground ? "是" : "否").append("\n");
        sb.append("目标：").append(prefs.getString("host", "（未填）"))
          .append(" : ").append(prefs.getInt("port", AltTabPipeService.DEFAULT_PORT)).append("\n");
        sb.append("接管名单：").append(prefs.getString("targets", AltTabPipeService.DEFAULT_TARGETS)).append("\n\n");
        sb.append("离开接管名单的应用后，过滤会自动关闭，普通打字不经过本应用。\n");
        sb.append("用法：填主机地址与接管名单 → 保存 → 打开无障碍并开启「AltTab 直通」。");
        status.setText(sb.toString());
    }

    private void send(final String payload) {
        final String host = prefs.getString("host", "");
        final int port = prefs.getInt("port", AltTabPipeService.DEFAULT_PORT);
        if (host.length() == 0) {
            Toast.makeText(this, "先填主机地址", Toast.LENGTH_SHORT).show();
            return;
        }
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                DatagramSocket s = null;
                try {
                    s = new DatagramSocket();
                    byte[] msg = payload.getBytes("UTF-8");
                    s.send(new DatagramPacket(msg, msg.length, InetAddress.getByName(host), port));
                    toast("已发送 " + payload + " → " + host + ":" + port);
                } catch (Exception e) {
                    toast("发送失败：" + e);
                } finally {
                    if (s != null) s.close();
                }
            }
        });
        t.setDaemon(true);
        t.start();
    }

    private void toast(final String m) {
        runOnUiThread(new Runnable() {
            @Override
            public void run() {
                Toast.makeText(MainActivity.this, m, Toast.LENGTH_LONG).show();
            }
        });
    }
}
