--[[--
汉字拼音标注插件 (Pinyin Annotator for KOReader)

仿 Kindle "生字注音" 功能: 在中文页面每个汉字上方(或下方)叠加拼音,
并可按"常用度等级"控制只给较生僻的字注音。

实现要点:
  * 通过 crengine 的 getPageXPointer / getNextVisibleChar 逐个字符遍历当前页,
    并用 getScreenBoxesFromPositions 取得每个字的屏幕坐标盒子;
  * 用 TextWidget 把拼音直接绘制到屏幕缓冲 Screen.bb 上, 再局部刷新。

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
-- 即等级越低, 只给越生僻的字注音; 等级 5 = 全文注音。
local LEVEL_THRESHOLD = {
    [1] = 7000,  -- 仅极生僻字
    [2] = 5500,
    [3] = 4000,  -- 默认
    [4] = 2500,
    [5] = 0,     -- 全部
}
local DEFAULT_LEVEL = 3

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

    local ok, pos0 = pcall(doc.getPageXPointer, doc, page)
    if not ok or not pos0 then return end
    local pos1 = doc:getPageXPointer(page + 1)
    if not pos1 then return end

    local face = Font:getFace(self.font_name, self.font_size)
    local pinyin_h = math.floor(self.font_size * 1.25)
    local threshold = LEVEL_THRESHOLD[self.level] or 4000
    local show_all = (self.level >= 5)
    local fgcolor = self.gray and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK

    -- 预扫描: 用 getNextVisibleChar 逐个字符遍历当前页(从页首 xpointer 走到页尾),
    -- 对每个字符用 getScreenBoxesFromPositions 取它的屏幕盒子, 用 getTextFromXPointers
    -- 取它的字。这样比一次性 getScreenBoxesFromPositions(整页) 更细粒度——
    -- 后者只返回 crengine 愿意暴露的少量文本段(如 23 个), 而逐字遍历能拿到每个字。
    local plan = {}
    local stats = { boxes = 0, words = 0, chars = 0,
                    with_data = 0, shown = 0, filtered = 0,
                    no_data = 0, no_word = 0 }
    local detail = {}
    local box_words = {}
    local MAX_DETAIL = 400

    local xp = pos0
    local iter = 0
    local MAX_ITER = 40000
    while xp and iter < MAX_ITER do
        iter = iter + 1
        -- compareXPointers 返回 1 表示 xp 在 pos1 之前(有序), 0 相同, -1 之后。
        -- 我们只要 xp 仍在当前页范围内(返回 1)就继续。
        local cmp = doc:compareXPointers(xp, pos1)
        if not cmp or cmp ~= 1 then break end

        local next_xp = doc:getNextVisibleChar(xp)
        if not next_xp or next_xp == xp then break end

        -- 取该字的屏幕盒子(用于定位)与文本(用于查拼音)
        local boxes = doc:getScreenBoxesFromPositions(xp, next_xp, true)
        local box = boxes and boxes[1]
        local tr = doc:getTextFromXPointers(xp, next_xp)
        local word = (type(tr) == "string" and tr)
                   or (type(tr) == "table" and tr.text) or ""

        if box or word ~= "" then
            stats.boxes = stats.boxes + 1
            stats.words = stats.words + 1
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
                local wshow = word:sub(1, 40)
                box_words[#box_words + 1] = string.format("#%d:%s%s",
                    stats.boxes, wshow, #word > 40 and "…" or "")
                local chars = {}
                for ch in word:gmatch(util.UTF8_CHAR_PATTERN) do
                    chars[#chars + 1] = ch
                end
                local n = #chars
                if n > 0 then
                    local item = { x = bx, y = by, w = bw, h = bh, chars = {} }
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
                                local cx = bx + (bw * (i - 0.5)) / n
                                item.chars[#item.chars + 1] = { ch = ch, py = py, cx = cx }
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
                    if #item.chars > 0 then
                        plan[#plan + 1] = item
                    end
                end
            end
        end

        xp = next_xp
    end

    if self.debug then
        logger.warn(string.format(
            "[Pinyin] page=%d level=%d show_all=%s thr=%d | boxes=%d words=%d chars=%d with_data=%d shown=%d filtered=%d no_data=%d no_word=%d iter=%d",
            page, self.level, tostring(show_all), threshold,
            stats.boxes, stats.words, stats.chars, stats.with_data,
            stats.shown, stats.filtered, stats.no_data, stats.no_word, iter))
        for _, l in ipairs(detail) do
            logger.warn("[Pinyin]" .. l)
        end
    end

    -- 保存诊断信息, 供菜单"查看诊断信息"直接弹窗(无需翻 crash.log)
    self.last_stats = stats
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
        text = _("汉字拼音 (Pinyin)"),
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
            table.insert(lines, string.format("计划页码 plan_page = %s", tostring(self.last_plan_page)))
            table.insert(lines, string.format("盒子数 boxes      = %d", s.boxes))
            table.insert(lines, string.format("取到字 words      = %d", s.words))
            table.insert(lines, string.format("取出字 chars      = %d", s.chars))
            table.insert(lines, string.format("有拼音数据        = %d", s.with_data))
            table.insert(lines, string.format("实际已注音 shown  = %d", s.shown))
            table.insert(lines, string.format("被等级过滤 filtered= %d", s.filtered))
            table.insert(lines, string.format("无拼音数据        = %d", s.no_data))
            table.insert(lines, string.format("取不到字 no_word  = %d", s.no_word))
            table.insert(lines, "")
            table.insert(lines, "判读:")
            table.insert(lines, "· no_word 很大 → 很多字取不到坐标(crengine 盒子问题)")
            table.insert(lines, "· level=5 但 filtered>0 → 等级逻辑异常")
            table.insert(lines, "· shown 远小于 chars → 大量字被等级过滤或数据缺失")
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
            UIManager:show(InfoMessage:new{
                text = _([[
汉字拼音标注 (Pinyin)

在中文页面每个汉字上方叠加拼音, 仿 Kindle "生字注音"。
· 标注等级: 控制只给多生僻的字注音(1 最严, 5 全文)。
· 已测试: EPUB / DOCX / HTML(建议用 EPUB); 其它格式未测试, 可能显示不出拼音。
· PDF / DjVu 因引擎限制暂不支持。
· 翻页后自动重绘; 关闭则清除标注。

数据来自 mozillazg/pinyin-data 与 Unicode Unihan 词频。]]),
            })
        end,
    })

    return sub
end

return Pinyin
