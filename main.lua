--[[--
汉字拼音标注插件 (Pinyin Annotator for KOReader)
Copyright (C) 2026 zhouwt — 以 GPL-3.0 协议发布 (见 LICENSE)

仿 Kindle "生字注音" 功能: 在中文页面每个汉字上方(或下方)叠加拼音,
并可按"常用度等级"控制只给较生僻的字注音。

性能优化(快筛+缓存+行级定位+时间预算)整合自社区改版, 字库与等级阈值沿用原版,
保留全文注音(等级 5)能力。

@module koplugin.Pinyin
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local PinyinData = require("pinyin_data")

-- 插件配置(config.lua): 两项高级开关, 默认均为关闭。修改后需重启 KOReader 生效。
local ok_cfg, PinyinConfig = pcall(require, "config")
if not ok_cfg or type(PinyinConfig) ~= "table" or PinyinConfig._pinyin ~= true then
    PinyinConfig = {}
end
local CFG_DEBUG_LOG = PinyinConfig.enable_debug_log == true
local CFG_SHOW_DIAG = PinyinConfig.show_diagnostics == true

-- 等级阈值: rank 越大越生僻。show = (等级==5) 或 (rank > 阈值)
-- 即等级越低, 只给越生僻的字注音; 等级 5 = 全文注音(沿用原版, 不用社区改版的等差优化)。
local LEVEL_THRESHOLD = {
    [1] = 7000,  -- 仅极生僻字
    [2] = 5500,
    [3] = 4000,  -- 默认
    [4] = 2500,
    [5] = 0,     -- 全部 (全文注音)
}
local DEFAULT_LEVEL = 3

-- 插件版本(与开发迭代号对齐, 每次改版递增)
local VERSION = "1.1"

local Pinyin = WidgetContainer:extend{
    name = "pinyin",
    is_doc_only = true,
}

function Pinyin:init()
    self.enabled = G_reader_settings:readSetting("pinyin_enabled", false)
    self.level = G_reader_settings:readSetting("pinyin_level", DEFAULT_LEVEL)
    self.font_size = G_reader_settings:readSetting("pinyin_font_size", 12)
    self.font_name = G_reader_settings:readSetting("pinyin_font", "cfont")
    self.position = "above"  -- 固定显示在汉字上方, 不开放修改
    self.gray = G_reader_settings:readSetting("pinyin_gray", false)
    self.debug = CFG_DEBUG_LOG  -- 由 config.lua 的 enable_debug_log 控制, 默认关闭
    self.show_diagnostics = CFG_SHOW_DIAG  -- 由 config.lua 的 show_diagnostics 控制, 默认关闭
    self.plan = {}  -- view module 绘制计划

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    if self.ui and self.ui.view and self.ui.view.registerViewModule then
        self.ui.view:registerViewModule("pinyin_overlay", self)
    end

    if self.enabled then
        -- 文档就绪后延迟绘制首屏(给 crengine/ReaderView 一点时间完成首屏渲染)
        UIManager:scheduleIn(0.3, function()
            self:drawPinyin()
        end)
    end
end

function Pinyin:onReaderReady()
    -- 注册为 ReaderView 的 view module, 这样每次页面重绘都会自动调用 paintTo,
    -- 拼音能稳定地画在页面内容之上, 不再依赖 setDirty 回调的时机。
    if self.ui and self.ui.view and self.ui.view.registerViewModule then
        self.ui.view:registerViewModule("pinyin_overlay", self)
    end
    if self.enabled then
        -- 文档就绪后再延迟一点, 确保当前页坐标已建立
        UIManager:scheduleIn(0.5, function()
            self:drawPinyin()
        end)
    end
end

function Pinyin:onPageUpdate(new_page)
    if self.enabled then
        -- 同步更新 plan: PageUpdate 事件在 ReaderView 重绘之前被广播,
        -- 此时把 plan 换成新页, 接下来的页面重绘就会直接画新页拼音。
        self:drawPinyin(new_page)
    end
end

-- 滚动模式下没有 PageUpdate, 而是 PosUpdate; 同时监听避免翻页/滚动后不刷新。
function Pinyin:onPosUpdate()
    if self.enabled then
        self:drawPinyin()
    end
end

-- 取得当前阅读页号
function Pinyin:getCurrentPage()
    if self.view and self.view.state and self.view.state.page then
        return self.view.state.page
    end
    local doc = self.ui and self.ui.document
    if doc and doc.getCurrentPage then
        local ok, p = pcall(doc.getCurrentPage, doc)
        if ok and p then return p end
    end
    return nil
end

-- 核心: 在当前页每个汉字上方/下方绘制拼音
-- target_page: 可选, 指定要绘制的页号; 不传则取当前页。
function Pinyin:drawPinyin(target_page)
    if not self.enabled then return end
    if not (self.ui and self.ui.dialog) then return end
    local doc = self.ui and self.ui.document
    if not doc or type(doc.getPageXPointer) ~= "function" then
        -- 仅支持 crengine 类文档; PDF/DjVu 暂不支持。已实测 EPUB/DOCX/HTML 可正常取字注音, 其它格式未充分测试(可能显示不出拼音)。
        return
    end
    local page = target_page or self:getCurrentPage()
    if self.debug then
        logger.warn(string.format("[Pinyin] drawPinyin called, target_page=%s current_page=%s",
            tostring(target_page), tostring(self:getCurrentPage())))
    end
    if not page or page < 1 then return end
    local t_start = os.clock()

    local ok, pos0 = pcall(doc.getPageXPointer, doc, page)
    if not ok or not pos0 then return end
    local pos1 = doc:getPageXPointer(page + 1)
    if not pos1 then return end

    local face = Font:getFace(self.font_name, self.font_size)
    local pinyin_h = math.floor(self.font_size * 1.25)
    local threshold = LEVEL_THRESHOLD[self.level] or 4000
    local show_all = (self.level >= 5)  -- 等级 5 = 全文注音(沿用原版)
    local fgcolor = self.gray and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK

    -- 快筛 + 缓存通道: 先一次性取整页文本(1 次 CRE 调用), 纯 Lua 查本页是否有
    -- 需要注音的字。绝大多数页面没有 → 直接返回, 完全跳过下面的逐字遍历
    -- (逐字遍历要 300~600 字 × 3 次 CRE 桥调用, 是翻页"长时间不动"的元凶)。
    -- 有目标字的页面才走逐字定位通道, 且结果按 (页码|等级|字号) 缓存,
    -- 翻回同一页零成本。
    local cache_key = string.format("%d|%d|%d", page, self.level, self.font_size)
    if not self._plan_cache then self._plan_cache = {} end
    if self._plan_cache[cache_key] ~= nil then
        -- 缓存命中: 直接复用上次的绘制计划, 同时把诊断数据也切到本页,
        -- 保证"诊断数字"始终对应当前页(旧版缓存命中不更新 last_stats,
        -- 导致诊断显示的是几页前的数据, 与页面注音对不上)。
        local cached = self._plan_cache[cache_key]
        self.plan = cached.plan or {}
        self.last_stats = cached.stats
        self.last_stats_page = cached.page or page
        self.last_detail = {}
        self.last_box_words = {}
        self.plan_face = face
        self.plan_pinyin_h = pinyin_h
        self.plan_fgcolor = fgcolor
        self.last_plan_page = page
        if self.ui and self.ui.dialog then
            UIManager:setDirty(self.ui.dialog, "ui")
        end
        return
    end

    local full_text = doc:getTextFromXPointers(pos0, pos1)
    if type(full_text) == "table" then
        full_text = full_text.text or ""
    end
    -- 快筛同时统计整页目标字总数(full_target_count), 供段级定位的覆盖校验用:
    -- 若行级盒子漏检了某些目标字, 据此判定回退全页遍历, 保证不丢注音。
    local full_target_count = 0
    if type(full_text) == "string" and full_text ~= "" then
        for ch in full_text:gmatch(util.UTF8_CHAR_PATTERN) do
            local entry = PinyinData.data[ch]
            if entry then
                local rk = tonumber(entry:match("|(%d+)$")) or 999999
                if rk > threshold then
                    full_target_count = full_target_count + 1
                end
            end
        end
        if full_target_count == 0 then
            -- 本页无目标字: 清空计划并返回, 翻页自身的重绘会自然清掉旧拼音,
            -- 不再请求额外重绘, 翻页开销降至接近零。
            self.plan = {}
            local empty_stats = { boxes = 0, words = 0, chars = 0,
                                  with_data = 0, shown = 0, filtered = 0,
                                  no_data = 0, elapsed_ms = 0 }
            self._plan_cache[cache_key] = { plan = {}, stats = empty_stats, page = page }
            self.last_stats = empty_stats
            self.last_stats_page = page
            self.last_detail = {}
            self.last_box_words = {}
            self.last_plan_page = page
            return
        end
    end

    -- 段级定位: 快筛已确认本页有目标字。先用 1 次调用取整页的行级盒子
    -- (getScreenBoxesFromPositions 返回约一页行数目的盒子, 屏幕坐标),
    -- 再对每个行盒用 getTextFromPositions 取该行文本与 xpointer 边界,
    -- 只对"确实含目标字"的行做逐字定位——把逐字遍历从"全页 300~600 字"
    -- 缩到"仅含目标字的行(每行约 20~50 字)", 生僻字越少的页省得越多。
    -- 行级命中的目标字总数与整页统计对比: 若行级漏检(某些行盒取不到文本),
    -- 自动回退全页逐字遍历, 功能优先、不丢注音。
    local plan = {}
    local stats = { boxes = 0, words = 0, chars = 0,
                    with_data = 0, shown = 0, filtered = 0,
                    no_data = 0, elapsed_ms = 0 }
    local detail = {}
    local box_words = {}
    local MAX_DETAIL = 400

    local iter = 0
    local MAX_ITER = 1500       -- 单页逐字上限: 一页最多约 600 字, 1500 足够, 防呆
    local BUDGET_SEC = 0.25     -- 单页处理耗时预算(秒): 超时立即停止扫描, 绝不长时间冻结 UI。
                                -- v5.4 曾降到 0.2s, 但 5 级(注音最多)实测 ~19% 的页仅超 3~4ms
                                -- 被整页放弃导致"页面没注音"; 放宽回 0.25s 并配合"超时画部分",
                                -- 实测 203/204ms 的页均能完成, 残余超时页也至少有部分拼音。
    local t0 = os.clock()       -- 预算计时起点
    local aborted = false       -- 超预算标志

    -- 1) 整页行盒 → 逐行取文本, 筛出含目标字的行, 得到待遍历的 (pos0, pos1) 区间
    local ranges = {}          -- 待逐字定位的区间列表
    local method = "FULL"      -- 实际使用的通道: SEG=仅目标行, FULL=整页(回退)
    local seg_target_count = 0 -- 行级命中的目标字总数(用于覆盖校验)
    local seg_boxes = doc:getScreenBoxesFromPositions(pos0, pos1, true)
    if seg_boxes and #seg_boxes > 0 then
        local seg_i = 0
        for _, sb in ipairs(seg_boxes) do
            seg_i = seg_i + 1
            -- 预算保护: 每处理 1 个行盒都检查耗时(含行内逐字统计成本),
            -- 超时立即放弃本页
            if os.clock() - t0 > BUDGET_SEC then
                aborted = true
                break
            end
            local tr = doc:getTextFromPositions(
                { x = sb.x, y = sb.y },
                { x = sb.x + sb.w, y = sb.y + sb.h },
                true)  -- do_not_draw_selection: 避免 crengine 每行都绘制选区高亮(重开销)
            if tr and tr.text and tr.text ~= "" and tr.pos0 and tr.pos1 then
                local n_t = 0
                for ch in tr.text:gmatch(util.UTF8_CHAR_PATTERN) do
                    local entry = PinyinData.data[ch]
                    if entry then
                        local rk = tonumber(entry:match("|(%d+)$")) or 999999
                        if rk > threshold then
                            n_t = n_t + 1
                        end
                    end
                end
                if n_t > 0 then
                    seg_target_count = seg_target_count + n_t
                    ranges[#ranges + 1] = { pos0 = tr.pos0, pos1 = tr.pos1 }
                end
            end
        end
        if seg_target_count >= full_target_count then
            -- 行级覆盖完整: 只遍历含目标字的行(最快通道)
            method = "SEG"
        else
            -- 行级漏检: 回退整页遍历, 保证注音不丢
            ranges = { { pos0 = pos0, pos1 = pos1 } }
        end
    else
        -- 行盒取不到: 直接整页遍历
        ranges = { { pos0 = pos0, pos1 = pos1 } }
    end

    -- 2) 逐字定位: 仅对目标行(或回退时的整页)做逐字遍历。
    --    每个字: 先取文本(便宜) → 拆字查拼音按等级过滤(纯 Lua) →
    --    确认要注音才取屏幕盒子(昂贵), 与整页通道的取字逻辑完全一致。
    for _, rg in ipairs(ranges) do
        local xp = rg.pos0
        while xp and iter < MAX_ITER do
            iter = iter + 1
            -- 预算保护: 每查 1 字都检查耗时(单字成本波动大, 实测约 0.5~1.8ms/字,
            -- 每字检查使最坏严格上界 = 预算 + 1 字成本, 不再有漏网窗口)
            if os.clock() - t0 > BUDGET_SEC then
                aborted = true
                break
            end
            -- compareXPointers 返回 1 表示 xp 在 rg.pos1 之前(有序), 0 相同, -1 之后。
            local cmp = doc:compareXPointers(xp, rg.pos1)
            if not cmp or cmp ~= 1 then break end

            local next_xp = doc:getNextVisibleChar(xp)
            if not next_xp or next_xp == xp then break end

            -- 先取该段的文本(便宜); 屏幕盒子留到确认有字要注音后再取(昂贵)。
            local tr = doc:getTextFromXPointers(xp, next_xp)
            local word = (type(tr) == "string" and tr)
                       or (type(tr) == "table" and tr.text) or ""

        if word ~= "" then
            stats.words = stats.words + 1
            if self.debug and #box_words < 512 then
                local wshow = word:sub(1, 40)
                box_words[#box_words + 1] = string.format("#%d:%s%s",
                    stats.words, wshow, #word > 40 and "…" or "")
            end
            -- 拆字并先做拼音查表与等级过滤(纯 Lua, 便宜)
            local chars = {}
            for ch in word:gmatch(util.UTF8_CHAR_PATTERN) do
                chars[#chars + 1] = ch
            end
            local n = #chars
            if n > 0 then
                local shown = {}
                for i, ch in ipairs(chars) do
                    stats.chars = stats.chars + 1
                    local entry = PinyinData.data[ch]
                    if entry then
                        stats.with_data = stats.with_data + 1
                        local py, rk = entry:match("([^|]+)|(%d+)")
                        rk = tonumber(rk) or 999999
                        local show = show_all or (rk > threshold)
                        if show and py then
                            stats.shown = stats.shown + 1
                            shown[#shown + 1] = { i = i, ch = ch, py = py }
                        else
                            stats.filtered = stats.filtered + 1
                            if self.debug and #detail < MAX_DETAIL then
                                detail[#detail + 1] = string.format(
                                    "  [filtered] '%s' rank=%d thr=%d",
                                    ch, rk, threshold)
                            end
                        end
                    else
                        stats.no_data = stats.no_data + 1
                        if self.debug and #detail < MAX_DETAIL then
                            detail[#detail + 1] = string.format("  [no-data] '%s'", ch)
                        end
                    end
                end
                -- 只有这一段确有要注音的字, 才取屏幕盒子(昂贵的 FFI 调用)
                if #shown > 0 then
                    local boxes = doc:getScreenBoxesFromPositions(xp, next_xp, true)
                    local box = boxes and boxes[1]
                    local bx, by, bw, bh
                    if box then
                        bx, by, bw, bh = box.x, box.y, box.w, box.h
                    else
                        -- 极少数情况盒子取不到, 退回用屏幕坐标定位(字宽按字号近似)
                        local sy, sx = doc:getScreenPositionFromXPointer(xp)
                        if sx and sy then
                            bx, by, bw, bh = sx, sy,
                                math.floor(self.font_size),
                                math.floor(self.font_size)
                        end
                    end
                    if bx then
                        stats.boxes = stats.boxes + 1
                        local item = { x = bx, y = by, w = bw, h = bh, chars = {} }
                        for _, s in ipairs(shown) do
                            local cx = bx + (bw * (s.i - 0.5)) / n
                            item.chars[#item.chars + 1] =
                                { ch = s.ch, py = s.py, cx = cx }
                        end
                        plan[#plan + 1] = item
                    end
                end
            end
        end

            xp = next_xp
        end
    end

    -- 超预算中止: 绝不长时间冻结 UI(死机根因)。与旧版"整页放弃"不同,
    -- 已扫出的拼音照常画出来并缓存, 页面至少有部分注音, 翻回也不重扫。
    if aborted then
        stats.aborted = true
        stats.elapsed_ms = math.floor((os.clock() - t_start) * 1000)
        if self.debug then
            logger.warn(string.format("[Pinyin] page=%d over budget (%.2fs), partial plan=%d kept, elapsed=%dms",
                page, BUDGET_SEC, #plan, stats.elapsed_ms))
        end
        -- 缓存部分计划: 翻回同一页直接复用, 不再重扫(避免再次超时/卡顿)
        self._plan_cache[cache_key] = { plan = plan, stats = stats, page = page }
        self.plan = plan
        self.plan_face = face
        self.plan_pinyin_h = pinyin_h
        self.plan_fgcolor = fgcolor
        self.last_plan_page = page
        self.last_stats = stats
        self.last_stats_page = page
        self.last_detail = {}
        self.last_box_words = {}
        -- 有部分拼音才请求重绘(空计划重绘纯浪费); 超时后尽量少打扰
        if #plan > 0 and self.ui and self.ui.dialog then
            UIManager:setDirty(self.ui.dialog, "ui")
        end
        return
    end

    -- 缓存本页绘制计划: 翻回同一页不再重扫。简单防膨胀: 超过 24 页缓存清空。
    self._plan_cache[cache_key] = { plan = plan, stats = stats, page = page }
    local n_cache = 0
    for _ in pairs(self._plan_cache) do
        n_cache = n_cache + 1
        if n_cache > 24 then
            self._plan_cache = {}
            break
        end
    end

    if self.debug then
        stats.elapsed_ms = math.floor((os.clock() - t_start) * 1000)
        logger.warn(string.format(
            "[Pinyin] page=%d level=%d thr=%d method=%s | boxes=%d words=%d chars=%d with_data=%d shown=%d filtered=%d no_data=%d iter=%d elapsed=%dms",
            page, self.level, threshold, method,
            stats.boxes, stats.words, stats.chars, stats.with_data,
            stats.shown, stats.filtered, stats.no_data, iter, stats.elapsed_ms))
        for _, l in ipairs(detail) do
            logger.warn("[Pinyin]" .. l)
        end
    end

    -- 保存诊断信息, 供菜单"查看诊断信息"直接弹窗(无需翻 crash.log)
    self.last_stats = stats
    self.last_stats_page = page
    self.last_detail = detail
    self.last_box_words = box_words

    -- 保存绘制计划与样式, 由 view module 的 paintTo 在页面重绘后自动绘制。
    self.plan = plan
    self.plan_face = face
    self.plan_pinyin_h = pinyin_h
    self.plan_fgcolor = fgcolor
    self.last_plan_page = page

    -- 请求 ReaderView 重绘, 重绘时会调用本插件的 paintTo, 把拼音画在页面之上。
    if self.ui and self.ui.dialog then
        if self.debug then
            logger.warn(string.format("[Pinyin] setDirty requested for page=%d", page))
        end
        UIManager:setDirty(self.ui.dialog, "ui")
    end
end

-- ReaderView 的 view module 绘制回调: 在每次页面重绘后被调用。
function Pinyin:paintTo(bb, x, y)
    if not self.enabled then return end
    if not self.plan or #self.plan == 0 then return end
    if self.debug then
        logger.warn(string.format("[Pinyin] paintTo called, plan_page=%s plan_items=%d",
            tostring(self.last_plan_page), #self.plan))
    end
    local face = self.plan_face
    local pinyin_h = self.plan_pinyin_h
    local fgcolor = self.plan_fgcolor
    if not face then return end
    for _, item in ipairs(self.plan) do
        for _, c in ipairs(item.chars) do
            local iy
            if self.position == "above" then
                if item.y >= pinyin_h then
                    iy = item.y - pinyin_h
                else
                    iy = item.y + item.h -- 顶部空间不足则改放下方
                end
            else
                iy = item.y + item.h
            end
            if iy >= 0 then
                local tw = TextWidget:new{
                    text = c.py, face = face, bold = false, fgcolor = fgcolor,
                }
                local tw_w = tw:getWidth()
                local ix = math.floor(c.cx - tw_w / 2)
                tw:paintTo(bb, ix + x, iy + y)
                tw:free()
            end
        end
    end
end

-- 关闭时清除已绘制的拼音: 清空计划并请求整屏重绘
function Pinyin:clearPinyin()
    self.plan = {}
    if self.ui and self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, "full")
    end
end

function Pinyin:addToMainMenu(menu_items)
    menu_items.pinyin = {
        text = _("汉字拼音"),
        -- 用 "tools" 排序提示, 把项放进主菜单的"工具"分组,
        -- 与"更多工具"分组是并列的同级分组(比嵌套在"更多工具"里更靠前、更显眼)。
        -- 注意: KOReader 插件项无法直接成为主菜单的一级按钮(需改 KOReader 核心),
        -- 放进某个一级分组是插件能稳定达到的最靠前位置。空 sorting_hint 会被当成
        -- "孤儿项"塞进分组数组、导致菜单项不显示甚至主菜单打不开(已踩坑验证)。
        sorting_hint = "tools",
        sub_item_table = self:genMenuItems(),
    }
end

function Pinyin:genMenuItems()
    local sub = {}

    table.insert(sub, {
        text_func = function()
            return self.enabled and _("关闭拼音标注") or _("开启拼音标注")
        end,
        checked = self.enabled,
        callback = function()
            self.enabled = not self.enabled
            G_reader_settings:saveSetting("pinyin_enabled", self.enabled)
            if self.enabled then
                if not (PinyinData and PinyinData.data and next(PinyinData.data)) then
                    UIManager:show(InfoMessage:new{
                        text = _("未找到拼音数据文件 pinyin_data.lua, 请先运行 generate_data.py 生成。"),
                    })
                    self.enabled = false
                    return
                end
                self:drawPinyin()
            else
                self:clearPinyin()
            end
        end,
    })

    table.insert(sub, {
        text_func = function()
            return T(_("标注等级: %1 (越大注音越多)"), self.level)
        end,
        help_text = _("标注等级 1-5(越大注音越多):\n1 级 = 仅最生僻字(罕见字才注)\n2 级 = 较生僻字\n3 级(默认) = 较生僻字注音(生字注音)\n4 级 = 覆盖面更广, 较常见的字也注\n5 级 = 全文注音, 每个字都标"),
        keep_menu_open = true,
        callback = function(touchmenu)
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = _("标注等级"),
                info_text = _("标注等级决定给多生僻的字注音 (rank 越小越常用):\n1 级:仅最生僻字 (rank>7000, 只注最罕见的一小部分)\n2 级:较生僻字 (rank>5500)\n3 级(默认):较生僻字注音 / 生字注音 (rank>4000)\n4 级:覆盖面更广, 较常见的字也注 (rank>2500)\n5 级:全文注音, 每个字都标 (rank>0)"),
                value = self.level, value_min = 1, value_max = 5, value_step = 1,
                ok_text = _("设定"),
                callback = function(spin)
                    self.level = spin.value
                    G_reader_settings:saveSetting("pinyin_level", self.level)
                    if self.enabled then self:drawPinyin() end
                    if touchmenu then touchmenu:updateItems() end
                end,
            })
        end,
    })

    table.insert(sub, {
        text_func = function()
            return T(_("拼音字号: %1"), self.font_size)
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = _("拼音字号"),
                info_text = _("拼音标注的字体大小(点)。"),
                value = self.font_size, value_min = 8, value_max = 28, value_step = 1,
                ok_text = _("设定"),
                callback = function(spin)
                    self.font_size = spin.value
                    G_reader_settings:saveSetting("pinyin_font_size", self.font_size)
                    if self.enabled then self:drawPinyin() end
                    if touchmenu then touchmenu:updateItems() end
                end,
            })
        end,
    })

    table.insert(sub, {
        text = _("颜色: 深灰"),
        checked = self.gray,
        callback = function()
            self.gray = not self.gray
            G_reader_settings:saveSetting("pinyin_gray", self.gray)
            if self.enabled then self:drawPinyin() end
        end,
    })

    table.insert(sub, {
        text = _("重新绘制本页拼音"),
        callback = function()
            self:drawPinyin()
        end,
    })

    if CFG_DEBUG_LOG then
    table.insert(sub, {
        text = _("调试日志 (写 KOReader 日志)"),
        checked = self.debug,
        callback = function()
            self.debug = not self.debug
            UIManager:show(InfoMessage:new{
                text = self.debug
                    and _("已开启调试日志。翻页/重绘后, 每个盒子的取字、拼音数据、等级过滤结果都会写入 KOReader 日志(crash.log)。")
                    or _("已关闭调试日志。"),
            })
        end,
    })
    end

    if CFG_SHOW_DIAG then
    table.insert(sub, {
        text = _("查看诊断信息"),
        keep_menu_open = true,
        callback = function()
            local s = self.last_stats
            if not s then
                UIManager:show(InfoMessage:new{
                    text = _("还没有诊断数据。请先开启拼音标注并翻几页, 再来查看。"),
                })
                return
            end
            local lines = {}
            table.insert(lines, string.format("本页统计 (level=%d):", self.level))
            table.insert(lines, string.format("统计数据页码 stats_page = %s", tostring(self.last_stats_page)))
            table.insert(lines, string.format("计划页码 plan_page     = %s", tostring(self.last_plan_page)))
            table.insert(lines, string.format("盒子数 boxes      = %d", s.boxes))
            table.insert(lines, string.format("取到字 words      = %d", s.words))
            table.insert(lines, string.format("取出字 chars      = %d", s.chars))
            table.insert(lines, string.format("有拼音数据        = %d", s.with_data))
            table.insert(lines, string.format("实际已注音 shown  = %d", s.shown))
            table.insert(lines, string.format("本页耗时 elapsed  = %dms", s.elapsed_ms or 0))
            table.insert(lines, string.format("被等级过滤 filtered= %d", s.filtered))
            table.insert(lines, string.format("无拼音数据        = %d", s.no_data))
            table.insert(lines, "")
            table.insert(lines, "判读:")
            if s.aborted then
                table.insert(lines, "· 本页扫描超时: 已显示找到的部分注音, 未注的字已缓存不再重扫")
            elseif s.words == 0 then
                table.insert(lines, "· 本页无目标字, 页面无拼音属正常")
            else
                table.insert(lines, "· shown 远小于 chars → 大量字被等级过滤或数据缺失")
            end
            if self.last_box_words and #self.last_box_words > 0 then
                table.insert(lines, "")
                table.insert(lines, string.format("本页盒子内容(%d 个):", #self.last_box_words))
                for _, bw in ipairs(self.last_box_words) do
                    table.insert(lines, "  " .. bw)
                end
            end
            if self.debug and self.last_detail and #self.last_detail > 0 then
                table.insert(lines, "")
                table.insert(lines, string.format("明细(前 %d 条):", #self.last_detail))
                for _, l in ipairs(self.last_detail) do
                    table.insert(lines, l)
                end
            end
            UIManager:show(TextViewer:new{
                title = _("汉字拼音诊断"),
                text = table.concat(lines, "\n"),
                width = math.floor(Screen:getWidth() * 0.9),
                height = math.floor(Screen:getHeight() * 0.9),
            })
        end,
    })
    end

    table.insert(sub, {
        text = _("关于 / 帮助"),
        keep_menu_open = true,
        callback = function()
            local about = string.format(
                "汉字拼音标注 (Pinyin)  v%s\n\n" ..
                "在中文页面每个汉字上方叠加拼音, 仿 Kindle \"生字注音\"。\n" ..
                "· 标注等级: 控制只给多生僻的字注音(1 最严, 5 全文)。\n" ..
                "· 已测试: EPUB / DOCX / HTML(建议用 EPUB); 其它格式未测试, 可能显示不出拼音。\n" ..
                "· PDF / DjVu 因引擎限制暂不支持。\n" ..
                "· 翻页后自动重绘; 关闭则清除标注。\n\n" ..
                "数据来自 mozillazg/pinyin-data 与 Unicode Unihan 词频。\n\n" ..
                "Copyright (C) 2026 zhouwt — 以 GPL-3.0 协议发布(见 LICENSE)。\n" ..
                "仓库: https://github.com/zhouwt/pinyin.koplugin",
                VERSION)
            UIManager:show(InfoMessage:new{ text = about })
        end,
    })

    return sub
end

return Pinyin
