# 二游情报铺 v2 · 社区 & 留声机 设计文档

## 1. 功能概览

| 模块 | 功能 | 技术方案 |
|------|------|----------|
| 首页汉堡菜单 | 新增"社区"和"留声机"入口 | 在现有 sidebar 中追加两个 sidebar-item |
| 社区 | 视频在线播放，按游戏分类 | B站 iframe 嵌入 + Waline 评论 |
| 留声机 | 音乐在线播放，按游戏分类 | Supabase Storage + HTML5 Audio |

---

## 2. 网盘文件夹结构

```
夸克网盘分享/
├── 崩坏星穹铁道/          ← 已有，游戏资料
├── 原神/
├── 异环/
├── ...
│
├── 【社区】/               ← 新增，视频区
│   ├── 崩坏：星穹铁道/
│   │   ├── 视频名称1/
│   │   │   ├── 简介.txt      ← 视频简介（纯文本）
│   │   │   └── bvid.txt      ← B站 BV 号（一行即可）
│   │   ├── 视频名称2/
│   │   │   ├── 简介.txt
│   │   │   └── bvid.txt
│   │   └── ...
│   ├── 原神/
│   ├── 异环/
│   └── 绝区零/
│
└── 【留声机】/             ← 新增，音乐区
    ├── 崩坏：星穹铁道/
    │   ├── 曲目名1/
    │   │   └── audio.mp3     ← 音频文件（建议 MP3/OGG）
    │   ├── 曲目名2/
    │   │   └── audio.mp3
    │   └── ...
    ├── 原神/
    ├── 异环/
    └── 绝区零/
```

**关键约定：**
- 社区视频文件夹名 = 视频标题
- 社区每个文件夹内必须有两个文件：`简介.txt`（简介内容）和 `bvid.txt`（B站BV号，如 `BV1xx411c7mD`）
- 留声机每个文件夹内放一个音频文件，文件名任意（如 `audio.mp3`）
- 封面图可选：如果文件夹内有 `.webp/.jpg/.png` 图片，自动用作封面

---

## 3. 社区模块详细设计

### 3.1 页面结构

```
社区首页
├── 游戏分类标签栏（全部 / 星穹铁道 / 原神 / 异环 / 绝区零）
├── 视频卡片网格（响应式，1-3列）
│   └── 每张卡片：封面 + 标题 + 时长 + 游戏名 + 播放数
└── 点击卡片 → 进入视频播放页

视频播放页（B站排版风格）
├── 返回按钮
├── B站嵌入播放器（iframe，16:9 比例）
├── 视频标题
├── 元信息（播放量 / 日期 / 游戏名）
├── 简介区域（可展开/收起，读取 txt）
├── 评论区（Waline）
└── 右侧推荐列表（同游戏其他视频）
```

### 3.2 B站嵌入方案

```html
<!-- 从 bvid.txt 读取 BV 号，嵌入播放器 -->
<iframe
  src="//player.bilibili.com/player.html?bvid=BV1xx411c7mD&high_quality=1&danmaku=0"
  allowfullscreen="true"
  sandbox="allow-top-navigation allow-same-origin allow-forms allow-scripts"
  style="width:100%;height:100%;border:none;">
</iframe>
```

**B站播放器自带功能：**
- ✅ 全屏
- ✅ 进度条
- ✅ 倍速（0.5x / 1.0x / 1.25x / 1.5x / 2.0x）
- ✅ 画质选择
- ❌ 弹幕（默认关闭，可开启）

### 3.3 评论系统 — Waline

- 部署在 Vercel（免费）
- 支持 Markdown 回复、表情、嵌套评论
- 不需要用户注册，匿名即可评论
- 数据存在 LeanCloud（免费额度够用）

```html
<!-- Waline 评论组件 -->
<div id="waline"></div>
<script src="https://unpkg.com/@waline/client@v3/dist/waline.js"></script>
<script>
  Waline.init({
    el: '#waline',
    serverURL: 'https://your-waline-app.vercel.app',
    path: '/community/video/xxx',  // 每个视频独立评论
  });
</script>
```

### 3.4 数据获取流程

```
用户进入社区
  ↓
遍历网盘【社区】文件夹
  ↓
解析每个视频文件夹：
  - 文件夹名 → 视频标题
  - 读取 bvid.txt → BV 号
  - 读取 简介.txt → 简介文本
  - 检测封面图 → 封面 URL
  ↓
生成视频列表数据 → 渲染卡片网格
```

---

## 4. 留声机模块详细设计

### 4.1 页面结构

```
留声机首页
├── 标题 + 副标题
├── 游戏分类标签（全部 / 各游戏）
├── 播放设置面板
│   ├── 后台播放开关
│   ├── 自动恢复进度开关
│   └── 进入时自动播放开关
├── 歌曲列表
│   └── 每首歌：序号 + 播放图标 + 曲名 + 艺术家 + 时长
└── 底部固定播放条
    ├── 进度条（可拖拽）
    ├── 封面缩略图
    ├── 曲名 + 艺术家
    ├── 时间显示（当前/总时长）
    ├── 控制按钮（上一首 / 播放暂停 / 下一首）
    └── 额外按钮（循环 / 列表）
```

### 4.2 音频托管方案

**方案：Supabase Storage**

```
存储桶：jukebox
路径格式：jukebox/{game}/{track_name}/audio.mp3
```

- Supabase 免费版：1GB 存储 + 2GB/月带宽
- 一首歌约 3-8MB，1GB 可存 120-300 首
- 每月 2GB 带宽 ≈ 250-600 次完整播放（按 3-8MB 算）
- 初期足够，用户量大了再考虑升级

### 4.3 播放进度记忆

使用 localStorage 存储：

```javascript
// 存储格式
{
  "jukebox_last_track": "星穹铁道-开拓之旅",
  "jukebox_last_position": 78.5,    // 秒
  "jukebox_settings": {
    "background_play": true,
    "auto_resume": true,
    "auto_play": false
  }
}
```

**自动恢复逻辑：**
1. 进入留声机 → 读取 localStorage
2. 如果有上次记录且"自动恢复"开启 → 定位到上次位置
3. 如果"自动播放"也开启 → 自动开始播放

### 4.4 后台播放实现

使用 HTML5 Audio API + Service Worker：

```javascript
// 音频播放核心
var audio = new Audio();
audio.src = "https://xxx.supabase.co/storage/v1/object/public/jukebox/...";
audio.play();

// 后台播放：即使切换 tab 也继续播放
// 这是 HTML5 Audio 的默认行为，无需额外处理
// 只需确保不主动 pause
```

---

## 5. 首页汉堡菜单修改

在现有 sidebar 中追加两个选项：

```html
<!-- 在现有侧边栏内容后追加 -->
<h3>探索</h3>
<button class="sidebar-item" onclick="showTab('community')">
  <svg><!-- 社区图标 --></svg>
  社区
</button>
<button class="sidebar-item" onclick="showTab('jukebox')">
  <svg><!-- 音乐图标 --></svg>
  留声机
</button>
```

---

## 6. 同步流程扩展

在现有 RUNBOOK 基础上，增加社区和留声机的同步步骤：

### 6.1 社区数据同步

- 遍历【社区】文件夹
- 每个视频文件夹生成一条记录存入 `community_data.json`
- 数据结构：

```json
{
  "games": {
    "崩坏：星穹铁道": {
      "videos": [
        {
          "title": "视频标题",
          "bvid": "BV1xx411c7mD",
          "desc": "简介文本...",
          "cover": "assets/community/cover-xxx.webp",
          "added_at": "2026-08-24"
        }
      ]
    }
  }
}
```

### 6.2 留声机数据同步

- 遍历【留声机】文件夹
- 音频文件上传到 Supabase Storage
- 生成曲目清单存入 `jukebox_data.json`：

```json
{
  "games": {
    "崩坏：星穹铁道": {
      "tracks": [
        {
          "name": "曲目名",
          "artist": "HOYO-MiX",
          "duration": "03:42",
          "url": "https://xxx.supabase.co/storage/v1/object/public/jukebox/hsr/track1/audio.mp3",
          "cover": null
        }
      ]
    }
  }
}
```

---

## 7. 需要创建/修改的文件

### 新建文件

| 文件 | 用途 |
|------|------|
| `community.html` | 社区页面（视频列表 + 播放） |
| `jukebox.html` | 留声机页面 |
| `community_data.json` | 社区视频数据 |
| `jukebox_data.json` | 留声机曲目数据 |

### 修改文件

| 文件 | 修改内容 |
|------|----------|
| `index.html` | 汉堡菜单追加社区和留声机入口；底部导航调整 |
| `generate.py` | 增加社区和留声机数据生成逻辑 |
| `sync/deploy.py` | 增加新文件上传规则 |
| `sync/RUNBOOK.md` | 增加社区和留声机同步步骤 |

### SQL（Supabase）

| 操作 | 用途 |
|------|------|
| 创建 Storage bucket `jukebox` | 存储音频文件 |
| 设置 bucket 为公开读取 | 允许前端直接播放 |

---

## 8. 部署成本

| 项目 | 成本 |
|------|------|
| GitHub Pages | 免费（已有） |
| Supabase Storage | 免费（1GB 存储 + 2GB/月带宽） |
| Waline 评论（Vercel） | 免费 |
| LeanCloud（Waline 后端） | 免费（1GB 存储 + 3万次/日 API） |
| **总计** | **¥0** |

---

## 9. 实施步骤

1. **搭框架**：创建 community.html 和 jukebox.html 页面骨架，接入现有样式
2. **修改首页**：汉堡菜单追加社区和留声机入口
3. **实现留声机**：HTML5 Audio 播放器 + 进度记忆 + 播放设置
4. **实现社区**：B站 iframe 嵌入 + 视频列表渲染 + 简介读取
5. **接入评论**：部署 Waline 到 Vercel，嵌入评论区
6. **数据同步**：扩展同步脚本，自动从网盘读取社区/留声机数据
7. **部署上线**：deploy.py 同步新文件到 GitHub Pages

---

## 10. 注意事项

- 社区和留声机是**免费公开内容**，不需要解锁即可访问
- B站视频建议设为"仅链接可见"或"不公开"，避免被搜索引擎收录
- 音频文件格式建议 MP3 (128kbps) 或 OGG，体积小、兼容好
- 留声机音频文件建议 < 10MB/首，节省 Supabase 带宽
- 社区视频不需要上传视频文件到任何地方，只需要 B站 BV 号
