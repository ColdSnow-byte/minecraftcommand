//! Minecraft 26.3 指令引擎
//!
//! 提供 brigadier 风格的指令解析：
//! - 光标处补全建议（suggestions）
//! - 光标处参数提示（hint）
//! - 带位置信息的语法错误（errors）
//! - 指令模拟执行（execute）

mod registry;

use registry as reg;

// ─────────────────────────── 暴露给 Dart 的类型 ───────────────────────────

/// 一条补全建议
#[derive(Clone)]
pub struct Suggestion {
    /// 插入到输入框的文本
    pub insert: String,
    /// 显示的主要文本
    pub label: String,
    /// 显示的说明文字
    pub detail: String,
    /// 插入后是否自动补一个空格
    pub append_space: bool,
}

/// 一条语法错误（带字符区间，可用来在输入框下标红）
#[derive(Clone, Debug)]
pub struct SyntaxError {
    pub message: String,
    /// 起始字符索引（char 计数，从 0 开始）
    pub start: i32,
    /// 结束字符索引（不含）
    pub end: i32,
}

/// 输入分析结果
#[derive(Clone)]
pub struct AnalysisResult {
    pub suggestions: Vec<Suggestion>,
    pub errors: Vec<SyntaxError>,
    /// 当前输入是否为一条完整、可执行的指令
    pub complete: bool,
    /// 光标处期望参数的中文提示
    pub hint: String,
    /// 当前指令的用法示例
    pub usage: String,
    /// 光标所在 token 的起始索引（用于补全替换）
    pub replace_start: i32,
}

/// 执行结果
#[derive(Clone)]
pub struct ExecutionResult {
    pub success: bool,
    pub message: String,
}

/// 指令信息（用于指令面板）
#[derive(Clone)]
pub struct CommandInfo {
    pub name: String,
    pub aliases: Vec<String>,
    pub usage: String,
    pub description: String,
    pub op_only: bool,
}

// ─────────────────────────── 参数类型 ───────────────────────────

#[derive(Clone, Copy, PartialEq)]
enum ArgType {
    Selector,
    Gamemode,
    Item,
    Effect,
    Enchant,
    Position,
    Int,
    Float,
    Bool,
    Time,
    Weather,
    Difficulty,
    Entity,
    Rule,
    RuleValue,
    Greedy,
    Json,
    XpUnit,
    TitleAction,
    FillMode,
    ClearMode,
    CloneMode,
    TimeQuery,
    // ── 扩展指令所需类型 ──
    /// 要执行的完整子指令（execute run 之后的部分）
    Command,
    /// 标识符（字母/数字/_-.）
    Word,
    /// 记分板目标名
    Objective,
    /// 记分板判据
    Criteria,
    /// 记分板显示槽位
    DisplaySlot,
    /// 记分板的数字渲染类型
    RenderType,
    /// `clone` 的过滤模式
    CloneFilter,
    /// 记分板运算符号（`+=`、`*=` 等）
    Operation,
    /// 结构名称（locate）
    Structure,
    /// 生物群系（locate biome）
    Biome,
    /// 伤害类型
    DamageType,
    /// 音效 ID
    Sound,
    /// 音效来源
    SoundSource,
    /// 颜色（bossbar/team）
    Color,
    /// bossbar 样式
    BarStyle,
    /// attribute 修饰符运算
    ModifierOp,
    /// 属性 ID
    Attribute,
    /// 物品栏槽位
    Slot,
    // ── 第二批补齐所需类型 ──
    /// 进度 ID
    Advancement,
    /// 粒子 ID
    Particle,
    /// 放置的地物/结构
    Feature,
    /// 手（主手/副手）
    Hand,
    // ── 带附加数据的参数 ──
    /// 带附加数据的物品：`diamond_sword[minecraft:enchantments={...}]`，
    /// 也兼容 1.20.4 以前的旧式写法 `diamond_sword{Enchantments:[...]}`（`/give` 用）
    ItemStack,
    /// 带方块状态或 NBT 的方块：`oak_stairs[facing=north]`、`chest{Items:[]}`
    BlockStack,
    /// 实体 / 方块的 NBT 复合标签：`{IsBaby:1b,CustomName:'"宝宝"'}`
    Nbt,
}

#[derive(Clone)]
enum Node {
    Lit(&'static str),
    Arg { name: &'static str, ty: ArgType, optional: bool },
}

struct Cmd {
    name: &'static str,
    aliases: &'static [&'static str],
    desc: &'static str,
    op: bool,
    branches: Vec<Vec<Node>>,
}

fn lit(s: &'static str) -> Node {
    Node::Lit(s)
}

fn arg(name: &'static str, ty: ArgType) -> Node {
    Node::Arg { name, ty, optional: false }
}

fn opt(name: &'static str, ty: ArgType) -> Node {
    Node::Arg { name, ty, optional: true }
}

fn pos3() -> Vec<Node> {
    vec![arg("x", ArgType::Position), arg("y", ArgType::Position), arg("z", ArgType::Position)]
}

fn commands() -> Vec<Cmd> {
    vec![
        Cmd {
            name: "gamemode",
            aliases: &[],
            desc: "更改游戏模式",
            op: true,
            branches: vec![
                vec![arg("mode", ArgType::Gamemode)],
                vec![arg("mode", ArgType::Gamemode), opt("target", ArgType::Selector)],
            ],
        },
        Cmd {
            name: "give",
            aliases: &[],
            desc: "给予玩家物品（可带物品组件或 NBT）",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector), arg("item", ArgType::ItemStack)],
                vec![arg("target", ArgType::Selector), arg("item", ArgType::ItemStack), opt("count", ArgType::Int)],
            ],
        },
        Cmd {
            name: "tp",
            aliases: &["teleport"],
            desc: "传送实体",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector)],
                vec![arg("target", ArgType::Selector), arg("destination", ArgType::Selector)],
                {
                    let mut v = vec![arg("target", ArgType::Selector)];
                    v.extend(pos3());
                    v.push(opt("yaw", ArgType::Float));
                    v.push(opt("pitch", ArgType::Float));
                    v
                },
                pos3(),
                {
                    let mut v = pos3();
                    v.push(opt("yaw", ArgType::Float));
                    v.push(opt("pitch", ArgType::Float));
                    v
                },
            ],
        },
        Cmd {
            name: "effect",
            aliases: &[],
            desc: "添加或清除状态效果",
            op: true,
            branches: vec![
                vec![lit("give"), arg("target", ArgType::Selector), arg("effect", ArgType::Effect)],
                vec![lit("give"), arg("target", ArgType::Selector), arg("effect", ArgType::Effect), opt("seconds", ArgType::Int)],
                vec![lit("give"), arg("target", ArgType::Selector), arg("effect", ArgType::Effect), opt("seconds", ArgType::Int), opt("amplifier", ArgType::Int)],
                vec![lit("give"), arg("target", ArgType::Selector), arg("effect", ArgType::Effect), opt("seconds", ArgType::Int), opt("amplifier", ArgType::Int), opt("hide_particles", ArgType::Bool)],
                vec![lit("clear"), opt("target", ArgType::Selector)],
                vec![lit("clear"), opt("target", ArgType::Selector), opt("effect", ArgType::Effect)],
            ],
        },
        Cmd {
            name: "enchant",
            aliases: &[],
            desc: "附魔玩家手中的物品",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector), arg("enchantment", ArgType::Enchant)],
                vec![arg("target", ArgType::Selector), arg("enchantment", ArgType::Enchant), opt("level", ArgType::Int)],
            ],
        },
        Cmd {
            name: "summon",
            aliases: &[],
            desc: "生成实体（可带 NBT）",
            op: true,
            branches: vec![
                vec![arg("entity", ArgType::Entity)],
                vec![arg("entity", ArgType::Entity), opt("nbt", ArgType::Nbt)],
                {
                    let mut v = vec![arg("entity", ArgType::Entity)];
                    v.extend(pos3());
                    v
                },
                {
                    let mut v = vec![arg("entity", ArgType::Entity)];
                    v.extend(pos3());
                    v.push(opt("nbt", ArgType::Nbt));
                    v
                },
            ],
        },
        Cmd {
            name: "setblock",
            aliases: &[],
            desc: "放置单个方块（可带方块状态或 NBT）",
            op: true,
            branches: vec![
                {
                    let mut v = pos3();
                    v.push(arg("block", ArgType::BlockStack));
                    v
                },
                {
                    let mut v = pos3();
                    v.push(arg("block", ArgType::BlockStack));
                    v.push(opt("mode", ArgType::ClearMode));
                    v
                },
            ],
        },
        Cmd {
            name: "fill",
            aliases: &[],
            desc: "填充区域方块（可带方块状态或 NBT）",
            op: true,
            branches: vec![
                {
                    let mut v = pos3();
                    v.extend(pos3());
                    v.push(arg("block", ArgType::BlockStack));
                    v
                },
                {
                    let mut v = pos3();
                    v.extend(pos3());
                    v.push(arg("block", ArgType::BlockStack));
                    v.push(opt("mode", ArgType::FillMode));
                    v
                },
            ],
        },
        Cmd {
            name: "clone",
            aliases: &[],
            desc: "复制区域方块",
            op: true,
            branches: vec![
                {
                    let mut v = pos3();
                    v.extend(pos3());
                    v.extend(pos3());
                    v
                },
                {
                    let mut v = pos3();
                    v.extend(pos3());
                    v.extend(pos3());
                    v.push(opt("filter", ArgType::CloneFilter));
                    v
                },
                {
                    let mut v = pos3();
                    v.extend(pos3());
                    v.extend(pos3());
                    v.push(opt("filter", ArgType::CloneFilter));
                    v.push(opt("mode", ArgType::CloneMode));
                    v
                },
            ],
        },
        Cmd {
            name: "kill",
            aliases: &[],
            desc: "杀死实体",
            op: true,
            branches: vec![vec![], vec![opt("target", ArgType::Selector)]],
        },
        Cmd {
            name: "clear",
            aliases: &[],
            desc: "清空玩家物品栏",
            op: true,
            branches: vec![
                vec![],
                vec![opt("target", ArgType::Selector)],
                vec![opt("target", ArgType::Selector), opt("item", ArgType::Item)],
                vec![opt("target", ArgType::Selector), opt("item", ArgType::Item), opt("count", ArgType::Int)],
            ],
        },
        Cmd {
            name: "time",
            aliases: &[],
            desc: "更改或查询时间",
            op: true,
            branches: vec![
                vec![lit("set"), arg("time", ArgType::Time)],
                vec![lit("add"), arg("amount", ArgType::Int)],
                vec![lit("query"), arg("type", ArgType::TimeQuery)],
            ],
        },
        Cmd {
            name: "weather",
            aliases: &[],
            desc: "设置天气",
            op: true,
            branches: vec![
                vec![arg("type", ArgType::Weather)],
                vec![arg("type", ArgType::Weather), opt("duration", ArgType::Int)],
            ],
        },
        Cmd {
            name: "difficulty",
            aliases: &[],
            desc: "设置游戏难度",
            op: true,
            branches: vec![vec![arg("level", ArgType::Difficulty)]],
        },
        Cmd {
            name: "say",
            aliases: &[],
            desc: "向所有玩家广播消息",
            op: false,
            branches: vec![vec![arg("message", ArgType::Greedy)]],
        },
        Cmd {
            name: "me",
            aliases: &[],
            desc: "以第三人称显示动作",
            op: false,
            branches: vec![vec![arg("action", ArgType::Greedy)]],
        },
        Cmd {
            name: "tellraw",
            aliases: &[],
            desc: "发送原始 JSON 消息",
            op: true,
            branches: vec![vec![arg("target", ArgType::Selector), arg("json", ArgType::Json)]],
        },
        Cmd {
            name: "title",
            aliases: &[],
            desc: "显示标题/副标题",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector), arg("action", ArgType::TitleAction), arg("text", ArgType::Greedy)],
                vec![arg("target", ArgType::Selector), lit("times"), arg("in", ArgType::Int), arg("stay", ArgType::Int), arg("out", ArgType::Int)],
            ],
        },
        Cmd {
            name: "xp",
            aliases: &["experience"],
            desc: "增加、设置或查询经验",
            op: true,
            branches: vec![
                vec![lit("add"), arg("target", ArgType::Selector), arg("amount", ArgType::Int)],
                vec![lit("add"), arg("target", ArgType::Selector), arg("amount", ArgType::Int), opt("unit", ArgType::XpUnit)],
                vec![lit("set"), arg("target", ArgType::Selector), arg("amount", ArgType::Int)],
                vec![lit("set"), arg("target", ArgType::Selector), arg("amount", ArgType::Int), opt("unit", ArgType::XpUnit)],
                vec![lit("query"), arg("target", ArgType::Selector), arg("amount", ArgType::Int)],
                vec![lit("query"), arg("target", ArgType::Selector), arg("amount", ArgType::Int), opt("unit", ArgType::XpUnit)],
            ],
        },
        Cmd {
            name: "spawnpoint",
            aliases: &[],
            desc: "设置出生点",
            op: true,
            branches: vec![
                vec![],
                vec![opt("target", ArgType::Selector)],
                {
                    let mut v = vec![opt("target", ArgType::Selector)];
                    v.extend(pos3());
                    v
                },
                {
                    let mut v = vec![opt("target", ArgType::Selector)];
                    v.extend(pos3());
                    v.push(opt("angle", ArgType::Float));
                    v
                },
            ],
        },
        Cmd {
            name: "gamerule",
            aliases: &[],
            desc: "设置游戏规则",
            op: true,
            branches: vec![
                vec![arg("rule", ArgType::Rule)],
                vec![arg("rule", ArgType::Rule), arg("value", ArgType::RuleValue)],
            ],
        },
        Cmd {
            name: "kick",
            aliases: &[],
            desc: "将玩家踢出服务器",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector)],
                vec![arg("target", ArgType::Selector), arg("reason", ArgType::Greedy)],
            ],
        },
        Cmd {
            name: "ban",
            aliases: &[],
            desc: "封禁玩家",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector)],
                vec![arg("target", ArgType::Selector), arg("reason", ArgType::Greedy)],
            ],
        },
        Cmd {
            name: "op",
            aliases: &[],
            desc: "给予玩家管理员权限",
            op: true,
            branches: vec![vec![arg("target", ArgType::Selector)]],
        },
        Cmd {
            name: "deop",
            aliases: &[],
            desc: "撤销玩家管理员权限",
            op: true,
            branches: vec![vec![arg("target", ArgType::Selector)]],
        },
        Cmd {
            name: "seed",
            aliases: &[],
            desc: "查看世界种子",
            op: false,
            branches: vec![vec![]],
        },
        Cmd {
            name: "list",
            aliases: &[],
            desc: "列出在线玩家",
            op: false,
            branches: vec![vec![]],
        },
        Cmd {
            name: "help",
            aliases: &[],
            desc: "查看指令帮助",
            op: false,
            branches: vec![vec![], vec![opt("command", ArgType::Greedy)]],
        },
        // ───────────── 必加 ─────────────
        Cmd {
            name: "execute",
            aliases: &[],
            desc: "以指定上下文执行子指令",
            op: true,
            branches: vec![
                vec![lit("as"), arg("target", ArgType::Selector), lit("run"), arg("command", ArgType::Command)],
                vec![lit("at"), arg("target", ArgType::Selector), lit("run"), arg("command", ArgType::Command)],
                vec![
                    lit("as"), arg("target", ArgType::Selector),
                    lit("at"), arg("at", ArgType::Selector),
                    lit("run"), arg("command", ArgType::Command),
                ],
                vec![lit("positioned"), arg("x", ArgType::Position), arg("y", ArgType::Position), arg("z", ArgType::Position), lit("run"), arg("command", ArgType::Command)],
                vec![
                    lit("as"), arg("target", ArgType::Selector),
                    lit("positioned"), arg("x", ArgType::Position), arg("y", ArgType::Position), arg("z", ArgType::Position),
                    lit("run"), arg("command", ArgType::Command),
                ],
                vec![lit("if"), lit("entity"), arg("target", ArgType::Selector), lit("run"), arg("command", ArgType::Command)],
                {
                    let mut v = vec![lit("if"), lit("block")];
                    v.extend(pos3());
                    v.push(arg("block", ArgType::BlockStack));
                    v.push(lit("run"));
                    v.push(arg("command", ArgType::Command));
                    v
                },
                vec![
                    lit("as"), arg("target", ArgType::Selector),
                    lit("if"), lit("entity"), arg("if_target", ArgType::Selector),
                    lit("run"), arg("command", ArgType::Command),
                ],
            ],
        },
        Cmd {
            name: "scoreboard",
            aliases: &[],
            desc: "管理记分板",
            op: true,
            branches: vec![
                // ── objectives ──
                vec![lit("objectives"), lit("list")],
                vec![
                    lit("objectives"),
                    lit("add"),
                    arg("objective", ArgType::Objective),
                    arg("criteria", ArgType::Criteria),
                ],
                vec![
                    lit("objectives"),
                    lit("add"),
                    arg("objective", ArgType::Objective),
                    arg("criteria", ArgType::Criteria),
                    opt("displayName", ArgType::Greedy),
                ],
                vec![lit("objectives"), lit("remove"), arg("objective", ArgType::Objective)],
                vec![
                    lit("objectives"),
                    lit("setdisplay"),
                    arg("slot", ArgType::DisplaySlot),
                    opt("objective", ArgType::Objective),
                ],
                vec![
                    lit("objectives"),
                    lit("modify"),
                    arg("objective", ArgType::Objective),
                    lit("displayname"),
                    arg("displayName", ArgType::Greedy),
                ],
                vec![
                    lit("objectives"),
                    lit("modify"),
                    arg("objective", ArgType::Objective),
                    lit("rendertype"),
                    arg("rendertype", ArgType::RenderType),
                ],
                vec![
                    lit("objectives"),
                    lit("modify"),
                    arg("objective", ArgType::Objective),
                    lit("numberformat"),
                    lit("styled"),
                ],
                vec![
                    lit("objectives"),
                    lit("modify"),
                    arg("objective", ArgType::Objective),
                    lit("numberformat"),
                    lit("blank"),
                ],
                vec![
                    lit("objectives"),
                    lit("modify"),
                    arg("objective", ArgType::Objective),
                    lit("numberformat"),
                    lit("fixed"),
                    arg("contents", ArgType::Greedy),
                ],
                // ── players ──
                vec![lit("players"), lit("list"), opt("target", ArgType::Selector)],
                vec![
                    lit("players"),
                    lit("get"),
                    arg("target", ArgType::Selector),
                    arg("objective", ArgType::Objective),
                ],
                vec![
                    lit("players"),
                    lit("set"),
                    arg("target", ArgType::Selector),
                    arg("objective", ArgType::Objective),
                    arg("score", ArgType::Int),
                ],
                vec![
                    lit("players"),
                    lit("add"),
                    arg("target", ArgType::Selector),
                    arg("objective", ArgType::Objective),
                    arg("score", ArgType::Int),
                ],
                vec![
                    lit("players"),
                    lit("remove"),
                    arg("target", ArgType::Selector),
                    arg("objective", ArgType::Objective),
                    arg("score", ArgType::Int),
                ],
                vec![
                    lit("players"),
                    lit("reset"),
                    arg("target", ArgType::Selector),
                    opt("objective", ArgType::Objective),
                ],
                vec![
                    lit("players"),
                    lit("enable"),
                    arg("target", ArgType::Selector),
                    arg("objective", ArgType::Objective),
                ],
                vec![
                    lit("players"),
                    lit("operation"),
                    arg("target", ArgType::Selector),
                    arg("objective", ArgType::Objective),
                    arg("operation", ArgType::Operation),
                    arg("source", ArgType::Selector),
                    arg("sourceObjective", ArgType::Objective),
                ],
                vec![
                    lit("players"),
                    lit("display"),
                    lit("name"),
                    arg("target", ArgType::Selector),
                    arg("objective", ArgType::Objective),
                    arg("displayName", ArgType::Greedy),
                ],
                vec![
                    lit("players"),
                    lit("display"),
                    lit("numberformat"),
                    arg("target", ArgType::Selector),
                    arg("objective", ArgType::Objective),
                    lit("styled"),
                ],
                vec![
                    lit("players"),
                    lit("display"),
                    lit("numberformat"),
                    arg("target", ArgType::Selector),
                    arg("objective", ArgType::Objective),
                    lit("blank"),
                ],
            ],
        },
        Cmd {
            name: "data",
            aliases: &[],
            desc: "读取或修改实体/方块 NBT 数据",
            op: true,
            branches: vec![
                vec![lit("get"), lit("entity"), arg("target", ArgType::Selector)],
                vec![lit("get"), lit("entity"), arg("target", ArgType::Selector), opt("path", ArgType::Word)],
                vec![lit("get"), lit("block"), arg("x", ArgType::Position), arg("y", ArgType::Position), arg("z", ArgType::Position)],
                vec![lit("merge"), lit("entity"), arg("target", ArgType::Selector), arg("nbt", ArgType::Nbt)],
                vec![lit("merge"), lit("block"), arg("x", ArgType::Position), arg("y", ArgType::Position), arg("z", ArgType::Position), arg("nbt", ArgType::Nbt)],
            ],
        },
        Cmd {
            name: "locate",
            aliases: &[],
            desc: "定位最近的结构或生物群系",
            op: false,
            branches: vec![
                vec![lit("structure"), arg("structure", ArgType::Structure)],
                vec![lit("biome"), arg("biome", ArgType::Biome)],
            ],
        },
        Cmd {
            name: "setworldspawn",
            aliases: &[],
            desc: "设置世界出生点",
            op: true,
            branches: vec![
                vec![],
                {
                    let mut v = pos3();
                    for n in &mut v {
                        if let Node::Arg { optional, .. } = n {
                            *optional = true;
                        }
                    }
                    v
                },
            ],
        },
        Cmd {
            name: "msg",
            aliases: &["tell", "w"],
            desc: "向玩家发送私信",
            op: false,
            branches: vec![vec![arg("target", ArgType::Selector), arg("message", ArgType::Greedy)]],
        },
        Cmd {
            name: "tag",
            aliases: &[],
            desc: "管理实体标签",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector), lit("add"), arg("name", ArgType::Word)],
                vec![arg("target", ArgType::Selector), lit("remove"), arg("name", ArgType::Word)],
                vec![arg("target", ArgType::Selector), lit("list")],
            ],
        },
        // ───────────── 推荐追加 ─────────────
        Cmd {
            name: "bossbar",
            aliases: &[],
            desc: "管理 Boss 血条",
            op: true,
            branches: vec![
                vec![lit("add"), arg("id", ArgType::Word), arg("name", ArgType::Json)],
                vec![lit("remove"), arg("id", ArgType::Word)],
                vec![lit("list")],
                vec![lit("get"), arg("id", ArgType::Word), opt("key", ArgType::Word)],
                vec![lit("set"), arg("id", ArgType::Word), lit("value"), arg("value", ArgType::Int)],
                vec![lit("set"), arg("id", ArgType::Word), lit("max"), arg("value", ArgType::Int)],
                vec![lit("set"), arg("id", ArgType::Word), lit("color"), arg("color", ArgType::Color)],
                vec![lit("set"), arg("id", ArgType::Word), lit("style"), arg("style", ArgType::BarStyle)],
                vec![lit("set"), arg("id", ArgType::Word), lit("visible"), arg("visible", ArgType::Bool)],
                vec![lit("set"), arg("id", ArgType::Word), lit("name"), arg("name", ArgType::Json)],
            ],
        },
        Cmd {
            name: "team",
            aliases: &[],
            desc: "管理队伍",
            op: true,
            branches: vec![
                vec![lit("list"), opt("team", ArgType::Word)],
                vec![lit("add"), arg("team", ArgType::Word), opt("display", ArgType::Json)],
                vec![lit("remove"), arg("team", ArgType::Word)],
                vec![lit("empty"), arg("team", ArgType::Word)],
                vec![lit("join"), arg("team", ArgType::Word), opt("target", ArgType::Selector)],
                vec![lit("leave"), arg("target", ArgType::Selector)],
                vec![lit("modify"), arg("team", ArgType::Word), lit("color"), arg("color", ArgType::Color)],
                vec![lit("modify"), arg("team", ArgType::Word), lit("friendlyFire"), arg("value", ArgType::Bool)],
            ],
        },
        Cmd {
            name: "playsound",
            aliases: &[],
            desc: "播放音效",
            op: true,
            branches: vec![
                vec![arg("sound", ArgType::Sound), arg("source", ArgType::SoundSource), arg("target", ArgType::Selector)],
                {
                    let mut v = vec![arg("sound", ArgType::Sound), arg("source", ArgType::SoundSource), arg("target", ArgType::Selector)];
                    v.extend(pos3());
                    v
                },
                {
                    let mut v = vec![arg("sound", ArgType::Sound), arg("source", ArgType::SoundSource), arg("target", ArgType::Selector)];
                    v.extend(pos3());
                    v.push(opt("volume", ArgType::Float));
                    v.push(opt("pitch", ArgType::Float));
                    v.push(opt("minVolume", ArgType::Float));
                    v
                },
            ],
        },
        Cmd {
            name: "stopsound",
            aliases: &[],
            desc: "停止音效",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector)],
                vec![arg("target", ArgType::Selector), arg("source", ArgType::SoundSource)],
                vec![arg("target", ArgType::Selector), arg("source", ArgType::SoundSource), opt("sound", ArgType::Sound)],
            ],
        },
        Cmd {
            name: "item",
            aliases: &[],
            desc: "修改实体/方块物品栏",
            op: true,
            branches: vec![
                vec![lit("replace"), lit("block"), arg("x", ArgType::Position), arg("y", ArgType::Position), arg("z", ArgType::Position), arg("slot", ArgType::Slot), arg("item", ArgType::ItemStack)],
                vec![lit("replace"), lit("block"), arg("x", ArgType::Position), arg("y", ArgType::Position), arg("z", ArgType::Position), arg("slot", ArgType::Slot), arg("item", ArgType::ItemStack), opt("count", ArgType::Int)],
                vec![lit("replace"), lit("entity"), arg("target", ArgType::Selector), arg("slot", ArgType::Slot), arg("item", ArgType::ItemStack)],
                vec![lit("replace"), lit("entity"), arg("target", ArgType::Selector), arg("slot", ArgType::Slot), arg("item", ArgType::ItemStack), opt("count", ArgType::Int)],
                vec![lit("modify"), lit("entity"), arg("target", ArgType::Selector), arg("slot", ArgType::Slot)],
            ],
        },
        Cmd {
            name: "worldborder",
            aliases: &[],
            desc: "管理世界边界",
            op: true,
            branches: vec![
                vec![lit("get")],
                vec![lit("set"), arg("distance", ArgType::Int)],
                vec![lit("set"), arg("distance", ArgType::Int), opt("seconds", ArgType::Int)],
                vec![lit("add"), arg("distance", ArgType::Int)],
                vec![lit("add"), arg("distance", ArgType::Int), opt("seconds", ArgType::Int)],
                vec![lit("center"), arg("x", ArgType::Position), arg("z", ArgType::Position)],
                vec![lit("damage"), lit("amount"), arg("value", ArgType::Float)],
                vec![lit("damage"), lit("buffer"), arg("value", ArgType::Float)],
                vec![lit("warning"), lit("distance"), arg("value", ArgType::Int)],
                vec![lit("warning"), lit("time"), arg("value", ArgType::Int)],
            ],
        },
        Cmd {
            name: "attribute",
            aliases: &[],
            desc: "管理实体属性",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector), arg("attribute", ArgType::Attribute), lit("get")],
                vec![arg("target", ArgType::Selector), arg("attribute", ArgType::Attribute), lit("base"), lit("get")],
                vec![arg("target", ArgType::Selector), arg("attribute", ArgType::Attribute), lit("base"), lit("set"), arg("value", ArgType::Float)],
                vec![arg("target", ArgType::Selector), arg("attribute", ArgType::Attribute), lit("modifier"), lit("add"), arg("id", ArgType::Word), arg("value", ArgType::Float), arg("op", ArgType::ModifierOp)],
                vec![arg("target", ArgType::Selector), arg("attribute", ArgType::Attribute), lit("modifier"), lit("remove"), arg("id", ArgType::Word)],
            ],
        },
        // ───────────── 服务器管理 ─────────────
        Cmd {
            name: "save-all",
            aliases: &[],
            desc: "保存世界",
            op: true,
            branches: vec![vec![], vec![lit("flush")]],
        },
        Cmd {
            name: "stop",
            aliases: &[],
            desc: "关闭服务器",
            op: true,
            branches: vec![vec![]],
        },
        Cmd {
            name: "pardon",
            aliases: &["unban"],
            desc: "解封玩家",
            op: true,
            branches: vec![vec![arg("target", ArgType::Word)]],
        },
        Cmd {
            name: "banlist",
            aliases: &[],
            desc: "查看封禁列表",
            op: true,
            branches: vec![vec![], vec![arg("type", ArgType::Word)]],
        },
        // ───────────── 其他 ─────────────
        Cmd {
            name: "clearspawnpoint",
            aliases: &[],
            desc: "清除玩家出生点",
            op: true,
            branches: vec![vec![], vec![opt("target", ArgType::Selector)]],
        },
        Cmd {
            name: "damage",
            aliases: &[],
            desc: "对实体造成伤害（可指定来源位置或来源实体）",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector), arg("amount", ArgType::Float)],
                vec![
                    arg("target", ArgType::Selector),
                    arg("amount", ArgType::Float),
                    arg("damageType", ArgType::DamageType),
                ],
                // `at <location>`：把伤害来源记在某个坐标上
                {
                    let mut v = vec![
                        arg("target", ArgType::Selector),
                        arg("amount", ArgType::Float),
                        arg("damageType", ArgType::DamageType),
                        lit("at"),
                    ];
                    v.extend(pos3());
                    v
                },
                // `by <entity>`：把伤害来源记在某个实体上
                vec![
                    arg("target", ArgType::Selector),
                    arg("amount", ArgType::Float),
                    arg("damageType", ArgType::DamageType),
                    lit("by"),
                    arg("entity", ArgType::Selector),
                ],
                // `by <entity> from <cause>`：再指定真正的起因
                vec![
                    arg("target", ArgType::Selector),
                    arg("amount", ArgType::Float),
                    arg("damageType", ArgType::DamageType),
                    lit("by"),
                    arg("entity", ArgType::Selector),
                    lit("from"),
                    arg("cause", ArgType::Selector),
                ],
            ],
        },
        Cmd {
            name: "ride",
            aliases: &[],
            desc: "让实体骑乘/下车",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector), lit("mount"), arg("vehicle", ArgType::Entity)],
                vec![arg("target", ArgType::Selector), lit("dismount")],
            ],
        },
        Cmd {
            name: "spectate",
            aliases: &[],
            desc: "旁观实体",
            op: true,
            branches: vec![
                vec![],
                vec![arg("entity", ArgType::Entity)],
                vec![arg("entity", ArgType::Entity), opt("target", ArgType::Selector)],
            ],
        },
        // ───────────── 第二批：世界与功能类 ─────────────
        Cmd {
            name: "advancement",
            aliases: &["advancements", "advancement"],
            desc: "授予或撤销进度",
            op: true,
            branches: vec![
                vec![lit("grant"), arg("target", ArgType::Selector), lit("everything")],
                vec![lit("grant"), arg("target", ArgType::Selector), lit("only"), arg("advancement", ArgType::Advancement)],
                vec![lit("revoke"), arg("target", ArgType::Selector), lit("everything")],
                vec![lit("revoke"), arg("target", ArgType::Selector), lit("only"), arg("advancement", ArgType::Advancement)],
            ],
        },
        Cmd {
            name: "defaultgamemode",
            aliases: &[],
            desc: "设置默认游戏模式",
            op: true,
            branches: vec![vec![arg("mode", ArgType::Gamemode)]],
        },
        Cmd {
            name: "function",
            aliases: &[],
            desc: "执行数据包函数",
            op: true,
            branches: vec![vec![arg("name", ArgType::Word)]],
        },
        Cmd {
            name: "loot",
            aliases: &[],
            desc: "生成战利品",
            op: true,
            branches: vec![
                vec![lit("give"), arg("target", ArgType::Selector), arg("table", ArgType::Word)],
                vec![lit("spawn"), arg("x", ArgType::Position), arg("y", ArgType::Position), arg("z", ArgType::Position), arg("table", ArgType::Word)],
                {
                    let mut v = vec![lit("replace"), lit("block")];
                    v.extend(pos3());
                    v.push(arg("slot", ArgType::Slot));
                    v.push(arg("table", ArgType::Word));
                    v
                },
                vec![lit("replace"), lit("entity"), arg("target", ArgType::Selector), arg("slot", ArgType::Slot), arg("table", ArgType::Word)],
            ],
        },
        Cmd {
            name: "particle",
            aliases: &[],
            desc: "生成粒子效果",
            op: true,
            branches: vec![
                vec![arg("particle", ArgType::Particle), arg("target", ArgType::Selector)],
                vec![arg("particle", ArgType::Particle), arg("x", ArgType::Position), arg("y", ArgType::Position), arg("z", ArgType::Position)],
                {
                    let mut v = vec![arg("particle", ArgType::Particle)];
                    v.extend(pos3());
                    v.extend(pos3());
                    v.push(arg("speed", ArgType::Float));
                    v.push(arg("count", ArgType::Int));
                    v
                },
                {
                    let mut v = vec![arg("particle", ArgType::Particle)];
                    v.extend(pos3());
                    v.extend(pos3());
                    v.push(arg("speed", ArgType::Float));
                    v.push(arg("count", ArgType::Int));
                    v.push(opt("normal", ArgType::Bool));
                    v
                },
            ],
        },
        Cmd {
            name: "place",
            aliases: &[],
            desc: "放置地物或结构",
            op: true,
            branches: vec![
                vec![lit("feature"), arg("feature", ArgType::Feature)],
                {
                    let mut v = vec![lit("feature"), arg("feature", ArgType::Feature)];
                    v.extend(pos3());
                    v
                },
                {
                    let mut v = vec![lit("structure"), arg("structure", ArgType::Feature)];
                    v.extend(pos3());
                    v
                },
                {
                    let mut v = vec![lit("jigsaw"), arg("pool", ArgType::Word), arg("target", ArgType::Word)];
                    v.extend(pos3());
                    v
                },
            ],
        },
        Cmd {
            name: "recipe",
            aliases: &[],
            desc: "授予或撤销配方",
            op: true,
            branches: vec![
                vec![lit("give"), arg("target", ArgType::Selector), arg("recipe", ArgType::Word)],
                vec![lit("take"), arg("target", ArgType::Selector), arg("recipe", ArgType::Word)],
            ],
        },
        Cmd {
            name: "reload",
            aliases: &[],
            desc: "重新加载数据包",
            op: true,
            branches: vec![vec![]],
        },
        Cmd {
            name: "schedule",
            aliases: &[],
            desc: "延时执行函数",
            op: true,
            branches: vec![
                vec![lit("function"), arg("name", ArgType::Word), arg("delay", ArgType::Int)],
                vec![lit("function"), arg("name", ArgType::Word), arg("delay", ArgType::Int), opt("append", ArgType::Word)],
                vec![lit("clear"), arg("name", ArgType::Word)],
            ],
        },
        Cmd {
            name: "spreadplayers",
            aliases: &[],
            desc: "将玩家随机分散到区域",
            op: true,
            branches: vec![vec![
                arg("center_x", ArgType::Position), arg("center_z", ArgType::Position),
                arg("spread", ArgType::Float), arg("max_range", ArgType::Float),
                arg("respect_teams", ArgType::Bool), arg("target", ArgType::Selector),
            ]],
        },
        Cmd {
            name: "teammsg",
            aliases: &["tm"],
            desc: "向队伍发送消息",
            op: false,
            branches: vec![vec![arg("message", ArgType::Greedy)]],
        },
        Cmd {
            name: "tick",
            aliases: &[],
            desc: "控制服务器 tick",
            op: true,
            branches: vec![
                vec![lit("query")],
                vec![lit("rate"), arg("rate", ArgType::Float)],
                vec![lit("sprint"), arg("ticks", ArgType::Int)],
                vec![lit("step"), opt("ticks", ArgType::Int)],
                vec![lit("freeze")],
                vec![lit("unfreeze")],
            ],
        },
        Cmd {
            name: "trigger",
            aliases: &[],
            desc: "触发记分板触发器",
            op: false,
            branches: vec![
                vec![arg("objective", ArgType::Objective)],
                vec![arg("objective", ArgType::Objective), lit("add"), arg("value", ArgType::Int)],
                vec![arg("objective", ArgType::Objective), lit("set"), arg("value", ArgType::Int)],
            ],
        },
        Cmd {
            name: "version",
            aliases: &[],
            desc: "查看服务器版本",
            op: false,
            branches: vec![vec![]],
        },
        Cmd {
            name: "forceload",
            aliases: &[],
            desc: "强制加载区块",
            op: true,
            branches: vec![
                vec![lit("add"), arg("from_x", ArgType::Position), arg("from_z", ArgType::Position)],
                vec![lit("add"), arg("from_x", ArgType::Position), arg("from_z", ArgType::Position), arg("to_x", ArgType::Position), arg("to_z", ArgType::Position)],
                vec![lit("remove"), arg("from_x", ArgType::Position), arg("from_z", ArgType::Position)],
                vec![lit("remove"), arg("from_x", ArgType::Position), arg("from_z", ArgType::Position), arg("to_x", ArgType::Position), arg("to_z", ArgType::Position)],
                vec![lit("remove"), lit("all")],
                vec![lit("query")],
                vec![lit("query"), arg("pos_x", ArgType::Position), arg("pos_z", ArgType::Position)],
            ],
        },
        Cmd {
            name: "fillbiome",
            aliases: &[],
            desc: "填充生物群系",
            op: true,
            branches: vec![vec![
                arg("from_x", ArgType::Position), arg("from_z", ArgType::Position),
                arg("to_x", ArgType::Position), arg("to_z", ArgType::Position),
                arg("biome", ArgType::Biome),
            ]],
        },
        Cmd {
            name: "random",
            aliases: &[],
            desc: "生成随机数",
            op: true,
            branches: vec![
                vec![lit("value"), arg("range", ArgType::Word)],
                vec![lit("value"), arg("range", ArgType::Word), opt("sequence", ArgType::Word)],
                vec![lit("roll"), arg("range", ArgType::Word)],
                vec![lit("roll"), arg("range", ArgType::Word), opt("sequence", ArgType::Word)],
                vec![lit("reset"), arg("sequence", ArgType::Word)],
            ],
        },
        Cmd {
            name: "return",
            aliases: &[],
            desc: "设置函数返回值",
            op: true,
            branches: vec![vec![arg("value", ArgType::Int)]],
        },
        Cmd {
            name: "rotate",
            aliases: &[],
            desc: "旋转实体朝向",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector), arg("yaw", ArgType::Float), arg("pitch", ArgType::Float)],
                vec![arg("target", ArgType::Selector), arg("yaw", ArgType::Float), arg("pitch", ArgType::Float), opt("duration", ArgType::Int)],
            ],
        },
        Cmd {
            name: "waypoint",
            aliases: &[],
            desc: "管理路点",
            op: true,
            branches: vec![
                vec![lit("list")],
                vec![lit("modify"), arg("name", ArgType::Word), lit("color"), arg("color", ArgType::Color)],
                vec![lit("modify"), arg("name", ArgType::Word), lit("tracking_status"), arg("status", ArgType::Word)],
            ],
        },
        Cmd {
            name: "stopwatch",
            aliases: &[],
            desc: "管理计时器",
            op: true,
            branches: vec![
                vec![lit("create"), arg("name", ArgType::Word)],
                vec![lit("start"), arg("name", ArgType::Word)],
                vec![lit("stop"), arg("name", ArgType::Word)],
                vec![lit("query"), arg("name", ArgType::Word)],
                vec![lit("list")],
            ],
        },
        Cmd {
            name: "datapack",
            aliases: &[],
            desc: "管理数据包",
            op: true,
            branches: vec![
                vec![lit("list")],
                vec![lit("list"), opt("filter", ArgType::Word)],
                vec![lit("enable"), arg("name", ArgType::Word)],
                vec![lit("disable"), arg("name", ArgType::Word)],
            ],
        },
        Cmd {
            name: "dialog",
            aliases: &[],
            desc: "显示或清除对话框",
            op: true,
            branches: vec![
                vec![lit("show"), arg("target", ArgType::Selector), arg("dialog", ArgType::Word)],
                vec![lit("clear"), arg("target", ArgType::Selector)],
            ],
        },
        Cmd {
            name: "swing",
            aliases: &[],
            desc: "挥动实体手臂",
            op: true,
            branches: vec![
                vec![],
                vec![opt("target", ArgType::Selector)],
                vec![opt("target", ArgType::Selector), arg("hand", ArgType::Hand)],
            ],
        },
        Cmd {
            name: "fetchprofile",
            aliases: &[],
            desc: "获取玩家档案",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Selector)],
                vec![arg("target", ArgType::Selector), opt("profile", ArgType::Word)],
            ],
        },
        Cmd {
            name: "posteffect",
            aliases: &[],
            desc: "设置屏幕后处理效果",
            op: true,
            branches: vec![
                vec![arg("effect", ArgType::Word)],
                vec![lit("clear")],
            ],
        },
        // ───────────── 第二批：服务器管理 ─────────────
        Cmd {
            name: "whitelist",
            aliases: &[],
            desc: "管理白名单",
            op: true,
            branches: vec![
                vec![lit("on")],
                vec![lit("off")],
                vec![lit("list")],
                vec![lit("add"), arg("target", ArgType::Word)],
                vec![lit("remove"), arg("target", ArgType::Word)],
                vec![lit("reload")],
            ],
        },
        Cmd {
            name: "ban-ip",
            aliases: &[],
            desc: "封禁 IP",
            op: true,
            branches: vec![
                vec![arg("target", ArgType::Word)],
                vec![arg("target", ArgType::Word), arg("reason", ArgType::Greedy)],
            ],
        },
        Cmd {
            name: "pardon-ip",
            aliases: &[],
            desc: "解封 IP",
            op: true,
            branches: vec![vec![arg("target", ArgType::Word)]],
        },
        Cmd {
            name: "setidletimeout",
            aliases: &[],
            desc: "设置挂机踢出时间",
            op: true,
            branches: vec![vec![arg("minutes", ArgType::Int)]],
        },
        Cmd {
            name: "save-off",
            aliases: &[],
            desc: "关闭自动保存",
            op: true,
            branches: vec![vec![]],
        },
        Cmd {
            name: "save-on",
            aliases: &[],
            desc: "启用自动保存",
            op: true,
            branches: vec![vec![]],
        },
        Cmd {
            name: "publish",
            aliases: &[],
            desc: "向局域网开放世界",
            op: true,
            branches: vec![vec![], vec![opt("port", ArgType::Int)]],
        },
        Cmd {
            name: "unpublish",
            aliases: &[],
            desc: "关闭局域网开放",
            op: true,
            branches: vec![vec![]],
        },
        Cmd {
            name: "transfer",
            aliases: &[],
            desc: "将玩家转移到其他服务器",
            op: true,
            branches: vec![
                vec![arg("host", ArgType::Word)],
                vec![arg("host", ArgType::Word), opt("port", ArgType::Int)],
            ],
        },
        Cmd {
            name: "perf",
            aliases: &[],
            desc: "性能分析报告",
            op: true,
            branches: vec![vec![lit("start")], vec![lit("stop")], vec![lit("clear")]],
        },
        Cmd {
            name: "debug",
            aliases: &[],
            desc: "调试信息与性能分析",
            op: true,
            branches: vec![vec![lit("start")], vec![lit("stop")], vec![lit("report")]],
        },
        Cmd {
            name: "jfr",
            aliases: &[],
            desc: "JFR 性能记录",
            op: true,
            branches: vec![vec![lit("start")], vec![lit("stop")]],
        },
        Cmd {
            name: "serverpack",
            aliases: &[],
            desc: "生成服务器资源包",
            op: true,
            branches: vec![vec![], vec![lit("pack")]],
        },
        Cmd {
            name: "debugconfig",
            aliases: &[],
            desc: "查询/修改调试配置",
            op: true,
            branches: vec![vec![arg("config", ArgType::Word)], vec![lit("config"), arg("config", ArgType::Word)]],
        },
        Cmd {
            name: "debugpath",
            aliases: &[],
            desc: "渲染实体寻路路径",
            op: true,
            branches: vec![vec![], vec![lit("start")], vec![lit("stop")]],
        },
        Cmd {
            name: "debugmobspawning",
            aliases: &[],
            desc: "调试生物生成",
            op: true,
            branches: vec![vec![], vec![lit("reset")], vec![lit("set"), arg("cooldown", ArgType::Int)]],
        },
        Cmd {
            name: "warden_spawn_tracker",
            aliases: &[],
            desc: "调试监守者生成追踪",
            op: true,
            branches: vec![vec![lit("reset")], vec![lit("set"), arg("value", ArgType::Int)]],
        },
        Cmd {
            name: "spawn_armor_trims",
            aliases: &[],
            desc: "生成盔甲纹饰",
            op: true,
            branches: vec![vec![]],
        },
        Cmd {
            name: "raid",
            aliases: &[],
            desc: "调试袭击",
            op: true,
            branches: vec![vec![lit("list"), arg("target", ArgType::Selector)], vec![lit("stop"), arg("target", ArgType::Selector)]],
        },
        Cmd {
            name: "chase",
            aliases: &[],
            desc: "调试指令追踪（开发版）",
            op: true,
            branches: vec![vec![arg("command", ArgType::Word)]],
        },
        Cmd {
            name: "test",
            aliases: &[],
            desc: "运行游戏测试",
            op: true,
            branches: vec![
                vec![lit("run"), arg("name", ArgType::Word)],
                vec![lit("runall"), opt("name", ArgType::Word)],
                vec![lit("resetall")],
                vec![lit("clearall")],
            ],
        },
    ]
}

// ─────────────────────────── 名字表 ───────────────────────────
//
// 方块 / 物品 / 实体 / 附魔 / 音效…… 全部集中在 `registry` 子模块里，
// 这里只负责参数校验、补全与执行，不再内嵌数据。







/// 校验标识符（字母/数字/_-.，可带命名空间前缀）
fn validate_word(s: &str) -> bool {
    if s.is_empty() || s.len() > 64 {
        return false;
    }
    s.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.' || c == ':' || c == '+' || c == '/')
}

/// 校验物品栏槽位（如 armor.head、container.5、weapon.mainhand）
fn validate_slot(s: &str) -> bool {
    let known = [
        "weapon", "weapon.mainhand", "weapon.offhand", "armor.head", "armor.chest",
        "armor.legs", "armor.feet", "armor.body", "saddle", "hotbar", "enderchest", "container",
    ];
    if known.contains(&s) {
        return true;
    }
    if let Some((head, tail)) = s.split_once('.') {
        if matches!(head, "container" | "hotbar" | "enderchest" | "weapon" | "armor") {
            return !tail.is_empty() && tail.chars().all(|c| c.is_ascii_digit());
        }
    }
    false
}

// ─────────────────────────── 校验与描述 ───────────────────────────

fn enum_values(ty: ArgType) -> Option<&'static [&'static str]> {
    match ty {
        ArgType::Gamemode => Some(&["survival", "creative", "adventure", "spectator"]),
        ArgType::BlockStack => Some(reg::blocks()),
        ArgType::Item | ArgType::ItemStack => Some(reg::items()),
        ArgType::Effect => Some(reg::EFFECTS),
        ArgType::Enchant => Some(reg::ENCHANTS),
        ArgType::Entity => Some(reg::ENTITIES),
        ArgType::Rule => Some(reg::GAMERULES),
        ArgType::Weather => Some(&["clear", "rain", "thunder"]),
        ArgType::Difficulty => Some(&["peaceful", "easy", "normal", "hard"]),
        ArgType::Bool => Some(&["true", "false"]),
        ArgType::FillMode => Some(&["destroy", "hollow", "keep", "outline", "replace"]),
        ArgType::ClearMode => Some(&["destroy", "keep", "replace"]),
        ArgType::CloneMode => Some(&["force", "move", "normal"]),
        ArgType::TimeQuery => Some(&["day", "daytime", "gametime"]),
        ArgType::XpUnit => Some(&["points", "levels"]),
        ArgType::TitleAction => Some(&["title", "subtitle", "actionbar"]),
        ArgType::Structure => Some(reg::STRUCTURES),
        ArgType::Biome => Some(reg::BIOMES),
        ArgType::DamageType => Some(reg::DAMAGE_TYPES),
        ArgType::Sound => Some(reg::SOUNDS),
        ArgType::SoundSource => Some(reg::SOUND_SOURCES),
        ArgType::Color => Some(reg::COLORS),
        ArgType::BarStyle => Some(reg::BAR_STYLES),
        ArgType::ModifierOp => Some(reg::MODIFIER_OPS),
        ArgType::Attribute => Some(reg::ATTRIBUTES),
        ArgType::Criteria => Some(reg::CRITERIA),
        ArgType::DisplaySlot => Some(reg::DISPLAY_SLOTS),
        ArgType::RenderType => Some(&["integer", "hearts"]),
        ArgType::Operation => Some(&["=", "+=", "-=", "*=", "/=", "%=", "><", "<", ">"]),
        ArgType::CloneFilter => Some(&["replace", "masked"]),
        ArgType::Advancement => Some(reg::ADVANCEMENTS),
        ArgType::Particle => Some(reg::PARTICLES),
        ArgType::Feature => Some(reg::PLACE_FEATURES),
        ArgType::Hand => Some(reg::HANDS),
        _ => None,
    }
}

fn describe(ty: ArgType) -> &'static str {
    match ty {
        ArgType::Selector => "目标选择器（@a 全体玩家 / @p 最近玩家 / @r 随机玩家 / @s 自己 / 玩家名）",
        ArgType::Gamemode => "游戏模式：survival / creative / adventure / spectator",
        ArgType::Item => "物品 ID，例如 diamond_sword",
        ArgType::Effect => "状态效果 ID，例如 speed、regeneration",
        ArgType::Enchant => "附魔 ID，例如 sharpness",
        ArgType::Position => "坐标值，支持数字、~ 相对坐标、^ 局部坐标",
        ArgType::Int => "整数",
        ArgType::Float => "数字（可带小数）",
        ArgType::Bool => "true 或 false",
        ArgType::Time => "时间：整数 tick 或 day / night / noon / midnight",
        ArgType::Weather => "天气：clear / rain / thunder",
        ArgType::Difficulty => "难度：peaceful / easy / normal / hard",
        ArgType::Entity => "实体 ID，例如 zombie、creeper",
        ArgType::Rule => "游戏规则名，例如 keepInventory",
        ArgType::RuleValue => "规则值：true / false 或整数",
        ArgType::Greedy => "任意文本",
        ArgType::Json => "JSON 文本，例如 {\"text\":\"你好\"}",
        ArgType::XpUnit => "points（点）或 levels（级）",
        ArgType::TitleAction => "title / subtitle / actionbar",
        ArgType::FillMode => "填充方式：destroy / hollow / keep / outline / replace",
        ArgType::ClearMode => "放置方式：destroy / keep / replace",
        ArgType::CloneMode => "克隆方式：force / move / normal",
        ArgType::TimeQuery => "查询对象：day / daytime / gametime",
        ArgType::Command => "要执行的完整子指令（如 give @a diamond）",
        ArgType::Word => "标识符（字母/数字/_-.）",
        ArgType::Objective => "记分板目标名（字母/数字/_-.+）",
        ArgType::Criteria => "判据：dummy / trigger / deathCount 等",
        ArgType::DisplaySlot => "显示槽位：sidebar / list / belowName 等",
        ArgType::RenderType => "数字渲染：integer（整数）或 hearts（心形）",
        ArgType::Operation => "运算：= / += / -= / *= / /= / %= / >< / < / >",
        ArgType::CloneFilter => "过滤：replace（全部复制）或 masked（只复制非空气方块）",
        ArgType::Structure => "结构名称，例如 village、ancient_city",
        ArgType::Biome => "生物群系，例如 plains、cherry_grove",
        ArgType::DamageType => "伤害类型，例如 fall、explosion",
        ArgType::Sound => "音效 ID，例如 entity.player.levelup",
        ArgType::SoundSource => "音效来源：master / music / block 等",
        ArgType::Color => "颜色，例如 red、gold、aqua",
        ArgType::BarStyle => "样式：progress / notched_10 等",
        ArgType::ModifierOp => "运算：add_value / add_multiplied_base / add_multiplied_total",
        ArgType::Attribute => "属性 ID，例如 generic.max_health",
        ArgType::Slot => "槽位，例如 armor.head、container.5",
        ArgType::Advancement => "进度 ID，例如 story/mine_diamond",
        ArgType::Particle => "粒子 ID，例如 flame、dust",
        ArgType::Feature => "地物名称，例如 village、ancient_city",
        ArgType::Hand => "mainhand 或 offhand",
        ArgType::ItemStack => {
            "物品 ID，可用 [组件] 附加数据（如 [minecraft:enchantments={levels:{\"minecraft:sharpness\":5}}]），也支持旧式 {...} NBT"
        }
        ArgType::BlockStack => "方块 ID，可带方块状态 [facing=north] 或 NBT {Items:[]}",
        ArgType::Nbt => "NBT 复合标签，例如 {IsBaby:1b} 或 {CustomName:'\"名字\"'}",
    }
}

fn validate_id(s: &str) -> bool {
    // 允许 minecraft: 前缀
    let id = s.strip_prefix("minecraft:").unwrap_or(s);
    !id.is_empty()
        && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

fn is_selector(s: &str) -> bool {
    if let Some(rest) = s.strip_prefix('@') {
        let head = rest.chars().next();
        return matches!(head, Some('a') | Some('e') | Some('p') | Some('r') | Some('s'));
    }
    !s.is_empty() && s.len() <= 16 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// 校验参数，Err 返回错误消息
fn validate_arg(ty: ArgType, s: &str) -> Result<(), String> {
    match ty {
        ArgType::Selector => {
            if is_selector(s) {
                Ok(())
            } else {
                Err("无效的目标选择器，应为 @a/@e/@p/@r/@s 或玩家名".into())
            }
        }
        ArgType::Int => s
            .parse::<i64>()
            .map(|_| ())
            .map_err(|_| format!("“{s}”不是有效的整数")),
        ArgType::Float | ArgType::Position => {
            let v = s.strip_prefix('~').or_else(|| s.strip_prefix('^')).unwrap_or(s);
            if v.is_empty() {
                return Ok(()); // 纯 ~ 或 ^
            }
            v.parse::<f64>()
                .map(|_| ())
                .map_err(|_| format!("“{s}”不是有效的坐标值"))
        }
        ArgType::Bool => {
            if s == "true" || s == "false" {
                Ok(())
            } else {
                Err("此处应为 true 或 false".into())
            }
        }
        ArgType::Greedy | ArgType::Json => {
            if ty == ArgType::Json && !(s.starts_with('{') || s.starts_with('"') || s.starts_with('[')) {
                Err("JSON 文本必须以 { 、 \" 或 [ 开头，例如 {\"text\":\"你好\"}".into())
            } else {
                Ok(())
            }
        }
        ArgType::Command => {
            // 递归校验完整子指令（光标置于末尾 = 全部 token 已完成）
            let inner = analyze(s.to_string(), (s.chars().count() + 1) as i32);
            if let Some(e) = inner.errors.first() {
                Err(format!("子指令错误：{}", e.message))
            } else if !inner.complete {
                Err(format!("子指令不完整，用法：{}", inner.usage))
            } else {
                Ok(())
            }
        }
        ArgType::Word | ArgType::Objective => {
            if validate_word(s) {
                Ok(())
            } else {
                Err(format!("“{s}”不是有效的名称（仅允许字母/数字/_-.+:）"))
            }
        }
        ArgType::Slot => {
            if validate_slot(s) {
                Ok(())
            } else {
                Err(format!("“{s}”不是有效的槽位（如 armor.head、container.5）"))
            }
        }
        ArgType::Time => {
            if matches!(s, "day" | "night" | "noon" | "midnight" | "sunrise" | "sunset") {
                return Ok(());
            }
            s.parse::<i64>()
                .map(|_| ())
                .map_err(|_| "时间应为整数 tick 或 day/night/noon/midnight".to_string())
        }
        ArgType::RuleValue => {
            if s == "true" || s == "false" {
                Ok(())
            } else {
                s.parse::<i64>().map(|_| ()).map_err(|_| "规则值应为 true、false 或整数".to_string())
            }
        }
        ArgType::ItemStack => validate_stack(reg::items(), s, "物品"),
        ArgType::BlockStack => validate_stack(reg::blocks(), s, "方块"),
        ArgType::Nbt => {
            if !s.starts_with('{') {
                return Err(format!("“{s}”不是 NBT 复合标签，应写成 {{...}} 形式"));
            }
            check_balanced(s)
        }
        ArgType::Item | ArgType::Entity => {
            let (table, kind) = match ty {
                ArgType::Item => (reg::items(), "物品"),
                _ => (reg::ENTITIES, "实体"),
            };
            validate_in_table(table, s, kind)
        }
        ArgType::Criteria => {
            let table = enum_values(ty).unwrap();
            let id = s.strip_prefix("minecraft:").unwrap_or(s);
            // 判据随版本增删很快（`teamkill.red`、`minecraft.custom:...` 之类），
            // 所以表内的直接放行，带 `.` / `:` 的统计类也放行，
            // 只拦 `dumy` 这种明显拼错的写法。
            if table.contains(&id) || s.contains('.') || s.contains(':') {
                Ok(())
            } else {
                Err(format!(
                    "未知的判据“{s}”，可选：dummy / trigger / deathCount / totalKillCount 等"
                ))
            }
        }
        ty if enum_values(ty).is_some() => {
            let table = enum_values(ty).unwrap();
            let id = s.strip_prefix("minecraft:").unwrap_or(s);
            if table.iter().any(|v| *v == id) {
                Ok(())
            } else {
                Err(format!("“{s}”无效，可选值：{}", table.iter().take(6).cloned().collect::<Vec<_>>().join(" / ")))
            }
        }
        _ => unreachable!("所有参数类型均已处理"),
    }
}

// ─────────────────────────── 物品附加数据（组件 / NBT） ───────────────────────────

/// 把 `diamond_sword[...]` / `diamond_sword{...}` 拆成 (物品 ID, 附加数据)
fn split_item_stack(s: &str) -> (&str, Option<&str>) {
    match s.find(|c| c == '[' || c == '{') {
        Some(i) => (&s[..i], Some(&s[i..])),
        None => (s, None),
    }
}

/// 校验「ID + 可选附加数据」：ID 必须在表里，附加数据必须括号配对、引号闭合。
///
/// 组件名 / 方块状态名本身**不做白名单校验**——它们随版本增删很快，
/// 硬报错容易误伤；名字是否正确交给补全列表去提示。
fn validate_stack(table: &'static [&'static str], s: &str, kind: &str) -> Result<(), String> {
    let (id, data) = split_item_stack(s);
    validate_in_table(table, id, kind)?;
    match data {
        Some(d) => check_balanced(d),
        None => Ok(()),
    }
}

/// 校验一个纯 ID 是否在给定注册表里
fn validate_in_table(table: &'static [&'static str], s: &str, kind: &str) -> Result<(), String> {
    if !validate_id(s) {
        return Err(format!("“{s}”不是有效的 ID 格式（小写字母/数字/下划线）"));
    }
    let id = s.strip_prefix("minecraft:").unwrap_or(s);
    if table.contains(&id) {
        Ok(())
    } else {
        Err(format!("未知的{kind}：“{s}”"))
    }
}

/// 校验 `[...]` / `{...}` / `"..."` 是否配对闭合
fn check_balanced(s: &str) -> Result<(), String> {
    let mut stack: Vec<char> = Vec::new();
    let mut in_string = false;
    let mut escaped = false;

    for ch in s.chars() {
        if in_string {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }
        match ch {
            '"' => in_string = true,
            '[' | '{' | '(' => stack.push(ch),
            ']' | '}' | ')' => {
                let want = match ch {
                    ']' => '[',
                    '}' => '{',
                    _ => '(',
                };
                if stack.pop() != Some(want) {
                    return Err(format!("附加数据的括号不匹配：“{s}”"));
                }
            }
            _ => {}
        }
    }

    if in_string {
        return Err(format!("附加数据里的字符串缺少结尾的引号：“{s}”"));
    }
    if let Some(&open) = stack.last() {
        let close = match open {
            '[' => ']',
            '{' => '}',
            _ => ')',
        };
        return Err(format!("附加数据缺少结尾的 “{close}”"));
    }
    Ok(())
}

/// 取出附加数据里顶层的键名（忽略嵌套括号与引号内的分隔符）
fn top_level_keys(inner: &str) -> Vec<String> {
    let chars: Vec<char> = inner.chars().collect();
    let mut keys = Vec::new();
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escaped = false;
    let mut start = 0usize;

    for (i, &ch) in chars.iter().enumerate() {
        if in_string {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }
        match ch {
            '"' => in_string = true,
            '[' | '{' | '(' => depth += 1,
            ']' | '}' | ')' => depth -= 1,
            ',' if depth == 0 => {
                push_key_segment(&chars[start..i], &mut keys);
                start = i + 1;
            }
            _ => {}
        }
    }
    push_key_segment(&chars[start..], &mut keys);
    keys
}

fn push_key_segment(segment: &[char], keys: &mut Vec<String>) {
    let text: String = segment.iter().collect();
    let text = text.trim();
    if text.is_empty() {
        return;
    }
    // 先按 `=` 切：现代组件是 `minecraft:damage=5`，键名本身带命名空间冒号；
    // 没有 `=` 再按 `:` 切：旧式 NBT 是 `Damage: 5`。
    let name = match text.split_once('=') {
        Some((key, _)) => key.trim(),
        None => text.split(|c| c == ':').next().unwrap_or(text).trim(),
    };
    let name = name.trim_matches('"');
    if !name.is_empty() {
        keys.push(name.to_string());
    }
}

/// 把附加数据概括成中文，用于执行后的反馈。例如
/// `[minecraft:enchantments={...}]` → `附魔`；
/// `{display:{...},Unbreakable:1}` → `展示信息（名称 / 描述 / 颜色）、无法破坏`
fn summarize_item_data(data: &str) -> Option<String> {
    let is_components = data.starts_with('[');
    let inner = data.strip_prefix('[').or_else(|| data.strip_prefix('{'))?;
    let inner = inner
        .strip_suffix(']')
        .or_else(|| inner.strip_suffix('}'))
        .unwrap_or(inner);

    let table: &[(&str, &str)] = if is_components {
        reg::ITEM_COMPONENTS
    } else {
        reg::LEGACY_NBT_KEYS
    };

    let mut parts: Vec<String> = Vec::new();
    for key in top_level_keys(inner) {
        let plain = key.trim_start_matches("minecraft:");
        let doc = table
            .iter()
            .find(|(name, _)| *name == key || name.trim_start_matches("minecraft:") == plain)
            .map(|(_, doc)| (*doc).to_string())
            .unwrap_or_else(|| plain.to_string());
        if !parts.contains(&doc) {
            parts.push(doc);
        }
    }

    if parts.is_empty() {
        None
    } else {
        Some(parts.join("、"))
    }
}

// ─────────────────────────── Token 化 ───────────────────────────

struct Token {
    text: String,
    start: usize, // char 索引
    end: usize,
}

/// 按空格切分（保留每个 token 的字符区间）。
///
/// 切分时跳过 `[...]` / `{...}` 内部和 `"..."` 之间的空格：物品组件与 NBT
/// 里经常带空格（`diamond_sword[minecraft:custom_name="Very Cool Sword"]`），
/// 按空格硬切会把一个参数拆成好几段。
fn tokenize(input: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut start: Option<usize> = None;
    let mut depth: i32 = 0;
    let mut in_string = false;
    let mut escaped = false;
    let total = input.chars().count();

    for (i, ch) in input.chars().enumerate() {
        // 先判断是否切分，再更新括号/引号状态，
        // 这样 `[` 本身仍归属当前 token。
        if ch == ' ' && depth == 0 && !in_string {
            if let Some(s) = start.take() {
                tokens.push(Token {
                    text: input.chars().skip(s).take(i - s).collect(),
                    start: s,
                    end: i,
                });
            }
        } else if start.is_none() {
            start = Some(i);
        }

        if in_string {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }
        match ch {
            '"' => in_string = true,
            '[' | '{' | '(' => depth += 1,
            ']' | '}' | ')' => depth -= 1,
            _ => {}
        }
        if depth < 0 {
            // 多余的右括号不该让后面再也切不开
            depth = 0;
        }
    }

    if let Some(s) = start {
        tokens.push(Token {
            text: input.chars().skip(s).take(total - s).collect(),
            start: s,
            end: total,
        });
    }
    tokens
}

/// 计算光标所在 token：返回 (token索引, 部分文本, replace_start)；
/// 若光标正处于新 token 起点（空格之后），返回 None。
fn locate_cursor(tokens: &[Token], cursor: usize, input: &str) -> Option<(usize, String, usize)> {
    for (i, t) in tokens.iter().enumerate() {
        if cursor > t.start && cursor <= t.end {
            return Some((i, t.text.clone(), t.start));
        }
        if cursor == t.start && cursor < t.end {
            return Some((i, t.text.clone(), t.start));
        }
    }
    // 光标在空格后 → 正在输入新 token
    let _ = input;
    None
}

/// 沿一个分支消费 tokens（0..n，即除光标 token 外的已完成部分），
/// 返回消费后可到达的节点位置集合；分支不匹配则返回空。
fn advance(branch: &[Node], tokens: &[Token], n: usize) -> Vec<usize> {
    let mut cur: Vec<usize> = vec![0];
    for (ti, tok) in tokens.iter().take(n).enumerate() {
        // Greedy / Command 节点必须位于分支末尾，吞掉剩余全部 token
        if let Some(&p) = cur.first() {
            if cur.len() == 1 && p < branch.len() {
                if let Node::Arg { ty: greedy_ty, .. } = &branch[p] {
                    if *greedy_ty == ArgType::Greedy || *greedy_ty == ArgType::Command {
                        if *greedy_ty == ArgType::Greedy {
                            cur = vec![p + 1];
                            break;
                        }
                        // Command：拼接剩余文本后递归校验。
                        // 宽松策略：仅当子指令存在硬语法错误时才判死分支，
                        // 输入过程中（尚未完整）保持存活以获得平滑的输入体验。
                        let joined = tokens[ti..n]
                            .iter()
                            .map(|t| t.text.clone())
                            .collect::<Vec<_>>()
                            .join(" ");
                        let inner = analyze(joined.clone(), (joined.chars().count() + 1) as i32);
                        if inner.errors.is_empty() {
                            cur = vec![p + 1];
                        } else {
                            cur = Vec::new();
                        }
                        break;
                    }
                }
            }
        }
        let mut next: Vec<usize> = Vec::new();
        for &p in &cur {
            if p >= branch.len() {
                continue; // 参数过多，此路径死亡
            }
            match &branch[p] {
                Node::Lit(w) => {
                    if tok.text == *w {
                        next.push(p + 1);
                    }
                }
                Node::Arg { ty, optional, .. } => {
                    if validate_arg(*ty, &tok.text).is_ok() {
                        next.push(p + 1);
                    }
                    if *optional && tok.text.is_empty() {
                        next.push(p);
                    }
                }
            }
        }
        next.sort_unstable();
        next.dedup();
        cur = next;
        if cur.is_empty() {
            break;
        }
    }
    cur.sort_unstable();
    cur.dedup();
    cur
}

// ─────────────────────────── 候选匹配 ───────────────────────────

/// 大小写不敏感的子串查找，返回匹配处的字节索引
fn find_ignore_case(haystack: &str, needle: &str) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    let h = haystack.as_bytes();
    let n = needle.as_bytes();
    if n.len() > h.len() {
        return None;
    }
    (0..=h.len() - n.len()).find(|&i| h[i..i + n.len()].eq_ignore_ascii_case(n))
}

/// 候选与输入的匹配打分，`None` 表示不匹配。分数越低越靠前：
///
/// - `0` 完全相同，`1` 前缀（`diam` → `diamond`）
/// - `2` 词首（`wool` → `white_wool`，按 `_ . / :` 分词）
/// - `10 + 位置` 普通子串（`eep` → `creeper`），位置越靠后越差
///
/// 这样「中间也能搜」，同时保证前缀命中永远排在最前面。
fn match_score(candidate: &str, query: &str) -> Option<u32> {
    if query.is_empty() {
        return Some(0);
    }
    let pos = find_ignore_case(candidate, query)?;

    if pos == 0 {
        return Some(if candidate.len() == query.len() { 0 } else { 1 });
    }
    if matches!(candidate.as_bytes()[pos - 1], b'_' | b'.' | b'/' | b':') {
        return Some(2);
    }
    Some(10 + pos as u32)
}

/// 候选按匹配质量排序：先按名字去重，再按分数排。
///
/// 预先算好分数再排序，避免比较阶段反复扫描字符串。
fn sort_suggestions(items: &mut Vec<Suggestion>, query: &str) {
    items.sort_by(|a, b| a.label.cmp(&b.label));
    items.dedup_by(|a, b| a.label == b.label);
    if query.is_empty() {
        return;
    }

    let mut scored: Vec<(u32, Suggestion)> = items
        .drain(..)
        .map(|s| (match_score(&s.label, query).unwrap_or(u32::MAX), s))
        .collect();
    scored.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.label.cmp(&b.1.label)));
    items.extend(scored.into_iter().map(|(_, s)| s));
}

fn node_candidates(node: &Node, partial: &str) -> Vec<Suggestion> {
    let mut out = Vec::new();
    match node {
        Node::Lit(w) => {
            if match_score(w, partial).is_some() {
                out.push(Suggestion {
                    insert: w.to_string(),
                    label: w.to_string(),
                    detail: "子指令".into(),
                    append_space: true,
                });
            }
        }
        Node::Arg { ty, .. } => {
            // 带附加数据的参数要深入 `[...]` / `{...}` 内部继续补全
            if *ty == ArgType::ItemStack {
                out.extend(data_stack_candidates(*ty, reg::items(), partial));
            } else if *ty == ArgType::BlockStack {
                out.extend(data_stack_candidates(*ty, reg::blocks(), partial));
            } else if *ty == ArgType::Nbt {
                out.extend(nbt_candidates(partial));
            } else if let Some(values) = enum_values(*ty) {
                for v in values {
                    if match_score(v, partial).is_some() {
                        out.push(Suggestion {
                            insert: v.to_string(),
                            label: v.to_string(),
                            detail: candidate_detail(*ty, v),
                            append_space: true,
                        });
                    }
                }
            } else {
                match ty {
                    ArgType::Selector => {
                        let opts: &[(&str, &str)] = &[
                            ("@a", "所有玩家"),
                            ("@p", "最近的玩家"),
                            ("@r", "随机玩家"),
                            ("@s", "指令执行者"),
                            ("@e", "所有实体"),
                        ];
                        for (v, d) in opts {
                            if match_score(v, partial).is_some() {
                                out.push(Suggestion {
                                    insert: v.to_string(),
                                    label: v.to_string(),
                                    detail: format!("目标选择器：{d}"),
                                    append_space: true,
                                });
                            }
                        }
                    }
                    ArgType::Position => {
                        for v in ["~", "^", "0"] {
                            if match_score(v, partial).is_some() {
                                out.push(Suggestion {
                                    insert: v.to_string(),
                                    label: v.to_string(),
                                    detail: describe(ArgType::Position).into(),
                                    append_space: false,
                                });
                            }
                        }
                    }
                    ArgType::Int => {
                        if match_score("1", partial).is_some() {
                            out.push(Suggestion {
                                insert: "1".into(),
                                label: "1".into(),
                                detail: describe(ArgType::Int).into(),
                                append_space: false,
                            });
                        }
                    }
                    ArgType::Time => {
                        for v in ["day", "night", "noon", "midnight", "1000"] {
                            if match_score(v, partial).is_some() {
                                out.push(Suggestion {
                                    insert: v.to_string(),
                                    label: v.to_string(),
                                    detail: "时间值".into(),
                                    append_space: true,
                                });
                            }
                        }
                    }
                    ArgType::Json => {
                        if match_score("{\"text\":\"", partial).is_some() {
                            out.push(Suggestion {
                                insert: "{\"text\":\"你好\"}".into(),
                                label: "{\"text\":\"...\"}".into(),
                                detail: "JSON 文本组件".into(),
                                append_space: false,
                            });
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    out
}

/// 补全候选右侧的说明文字。
///
/// 优先给出**这一条自己的中文名**：`aqua_affinity` → 水下速掘、
/// `diamond_sword` → 钻石剑、`zombie` → 僵尸。
/// 词典里查不到（例如进度 ID、显示槽位）才退回该参数类型的通用说明。
fn candidate_detail(ty: ArgType, value: &str) -> String {
    // 音效来源是独立语义：`block` / `music` / `record` 这些词在物品上下文里
    // 是别的意思，所以单独给一套说法。
    if ty == ArgType::SoundSource {
        return match value {
            "master" => "主音量（全部音效）",
            "music" => "背景音乐",
            "record" => "唱片机",
            "weather" => "天气",
            "block" => "方块音效",
            "hostile" => "敌对生物",
            "neutral" => "中立生物",
            "player" => "玩家",
            "ambient" => "环境音",
            "voice" => "语音",
            _ => describe(ty),
        }
        .to_string();
    }

    let zh = reg::localize(value);
    if zh == value {
        describe(ty).to_string()
    } else {
        zh
    }
}

/// 带附加数据的参数的候选（物品 / 方块通用）：
/// - 还没写 `[` / `{` → 补 ID 本身；
/// - 写了 `[` → 补物品组件名；
/// - 写了 `{` → 补 NBT 键名。
///
/// 插入的文本都是**整个 token**（`diamond[minecraft:enchantments=`），
/// 因为补全替换的是光标所在的整个 token。
fn data_stack_candidates(
    ty: ArgType,
    table: &'static [&'static str],
    partial: &str,
) -> Vec<Suggestion> {
    let Some(open) = partial.find(|c| c == '[' || c == '{') else {
        return table
            .iter()
            .filter(|v| match_score(v, partial).is_some())
            .map(|v| Suggestion {
                insert: (*v).to_string(),
                label: (*v).to_string(),
                detail: candidate_detail(ty, v),
                append_space: true,
            })
            .collect();
    };

    let head = &partial[..open];
    let inner = &partial[open + 1..];
    let (before, segment) = split_last_segment(inner);

    // `{Key: value}` → NBT 键名
    if partial.as_bytes()[open] == b'{' {
        return nbt_key_candidates(head, before, segment);
    }

    // 方块状态是每个方块各自一套枚举，猜不出该给什么，就不给候选
    if ty == ArgType::BlockStack {
        return Vec::new();
    }

    // `[组件=值]`，允许省略 `minecraft:` 前缀
    let typing_namespace = segment.starts_with("minecraft:");
    let partial_name = segment.strip_prefix("minecraft:").unwrap_or(segment);
    let mut hits: Vec<&(&str, &str)> = reg::ITEM_COMPONENTS
        .iter()
        .filter(|(name, _)| {
            let plain = name.trim_start_matches("minecraft:");
            if typing_namespace {
                // 已经敲到命名空间了，就只按组件名本身匹配
                match_score(plain, partial_name).is_some()
            } else {
                match_score(name, segment).is_some() || match_score(plain, segment).is_some()
            }
        })
        .collect();
    // 短名优先：`lore` / `damage` / `food` 这类常用组件更容易被选中
    hits.sort_by_key(|entry| entry.0.len());

    hits.into_iter()
        .map(|&(name, doc)| Suggestion {
            insert: format!("{head}[{before}{name}="),
            label: name.to_string(),
            detail: doc.to_string(),
            append_space: false,
        })
        .collect()
}

/// NBT 参数（`/summon`、`/data merge` 等）的候选
fn nbt_candidates(partial: &str) -> Vec<Suggestion> {
    let Some(inner) = partial.strip_prefix('{') else {
        // 还没开始写，先给个骨架
        return vec![Suggestion {
            insert: "{".to_string(),
            label: "{...}".to_string(),
            detail: describe(ArgType::Nbt).to_string(),
            append_space: false,
        }];
    };
    let (before, segment) = split_last_segment(inner);
    nbt_key_candidates("", before, segment)
}

/// 补 NBT 键名。[prefix] 是已经写好的开头（物品 ID 或空串）
fn nbt_key_candidates(prefix: &str, before: &str, segment: &str) -> Vec<Suggestion> {
    reg::LEGACY_NBT_KEYS
        .iter()
        .filter(|(name, _)| match_score(name, segment).is_some())
        .map(|(name, doc)| Suggestion {
            insert: format!("{prefix}{{{before}{name}:"),
            label: (*name).to_string(),
            detail: (*doc).to_string(),
            append_space: false,
        })
        .collect()
}

/// 把「已经写完的组件」与「正在输入的这一段」分开：
/// `a=1,b=2` → (`a=1,`, `b=2`)。会跳过嵌套括号与字符串里的逗号。
fn split_last_segment(inner: &str) -> (&str, &str) {
    let mut depth = 0i32;
    let mut in_string = false;
    let mut escaped = false;
    let mut separator: Option<usize> = None;

    for (i, ch) in inner.char_indices() {
        if in_string {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }
        match ch {
            '"' => in_string = true,
            '[' | '{' | '(' => depth += 1,
            ']' | '}' | ')' => depth -= 1,
            ',' if depth <= 0 => separator = Some(i),
            _ => {}
        }
    }

    match separator {
        Some(i) => (&inner[..=i], inner[i + 1..].trim_start()),
        None => ("", inner.trim_start()),
    }
}

fn build_usage(cmd: &Cmd) -> String {
    let branch = &cmd.branches[0];
    let mut s = format!("/{}", cmd.name);
    for n in branch {
        match n {
            Node::Lit(w) => s.push_str(&format!(" {w}")),
            Node::Arg { name, optional, .. } => {
                if *optional {
                    s.push_str(&format!(" [{name}]"));
                } else {
                    s.push_str(&format!(" <{name}>"));
                }
            }
        }
    }
    s
}

// ─────────────────────────── 核心 API ───────────────────────────

/// 实时分析输入：补全建议 + 语法错误 + 光标提示
pub fn analyze(input: String, cursor: i32) -> AnalysisResult {
    let raw_cursor = cursor.max(0) as usize; // 允许超出末尾（表示所有 token 已完成）
    let chars: Vec<char> = input.chars().collect();
    let cursor = raw_cursor.min(chars.len());

    let empty = AnalysisResult {
        suggestions: Vec::new(),
        errors: Vec::new(),
        complete: false,
        hint: "输入指令，例如 /give".into(),
        usage: String::new(),
        replace_start: cursor as i32,
    };

    // 去掉开头的 '/'
    let stripped_start = if chars.first() == Some(&'/') { 1 } else { 0 };
    let body: String = chars[stripped_start.min(chars.len())..].iter().collect();
    let tokens = tokenize(&body);

    if tokens.is_empty() {
        let suggestions = commands()
            .iter()
            .map(|c| Suggestion {
                insert: format!("/{}", c.name),
                label: c.name.to_string(),
                detail: format!("{}{}", c.desc, if c.op { "（需要 OP）" } else { "" }),
                append_space: false,
            })
            .collect();
        return AnalysisResult { suggestions, hint: "输入指令名称".to_string(), ..empty };
    }

    // 定位光标
    let body_char_offset = stripped_start;
    let active = locate_cursor(&tokens, raw_cursor.saturating_sub(body_char_offset), &body);
    let (active_idx, partial, replace_start) = match active {
        Some(v) => v,
        None => (tokens.len(), String::new(), cursor.saturating_sub(body_char_offset)),
    };

    let replace_start_abs = (replace_start + body_char_offset) as i32;

    // 第一个 token：指令名（不属于分支节点）
    let all_cmds = commands();
    let cmd_token = &tokens[0];
    let matched: Vec<&Cmd> = all_cmds
        .iter()
        .filter(|c| c.name == cmd_token.text || c.aliases.contains(&cmd_token.text.as_str()))
        .collect();

    if matched.is_empty() {
        // 若还在输入指令名，则给建议；否则报错
        let exact_hint = active_idx == 0;
        let mut suggestions = Vec::new();
        if exact_hint {
            for c in commands() {
                if match_score(c.name, &partial).is_some()
                    || c.aliases.iter().any(|a| match_score(a, &partial).is_some())
                {
                    suggestions.push(Suggestion {
                        insert: c.name.to_string(),
                        label: c.name.to_string(),
                        detail: format!("{}{}", c.desc, if c.op { "（需要 OP）" } else { "" }),
                        append_space: true,
                    });
                }
            }
        }
        let errors = if exact_hint {
            Vec::new()
        } else {
            vec![SyntaxError {
                message: format!("未知指令：/{}", cmd_token.text),
                start: cmd_token.start as i32 + body_char_offset as i32,
                end: cmd_token.end as i32 + body_char_offset as i32,
            }]
        };
        return AnalysisResult {
            suggestions,
            errors,
            hint: "指令名称".to_string(),
            usage: String::new(),
            complete: false,
            replace_start: replace_start_abs,
        };
    }

    let cmd = matched[0];

    // execute 指令使用专用子句解析器（支持内层子指令的补全与错误定位）
    if cmd.name == "execute" {
        return analyze_execute(&body, &tokens, body_char_offset, raw_cursor.saturating_sub(body_char_offset), replace_start_abs);
    }

    // 已完成的“参数”token（排除指令名本身）
    let arg_tokens = &tokens[1..];
    let n_completed_args = active_idx.saturating_sub(1);
    let completed = &arg_tokens[..n_completed_args.min(arg_tokens.len())];

    // 已完成参数的可达位置（按各分支）
    let mut alive: Vec<(usize, Vec<usize>)> = Vec::new(); // (branch索引, 可达位置)
    for (bi, branch) in cmd.branches.iter().enumerate() {
        let positions = advance(branch, completed, completed.len());
        if !positions.is_empty() {
            alive.push((bi, positions));
        }
    }

    // 检查光标之前是否已经出错（例如某个已完成 token 匹配失败）
    if alive.is_empty() {
        // 找到第一个失败的参数 token，给出精确错误
        return first_error_result(cmd, &tokens[1..], body_char_offset, replace_start_abs, completed.len());
    }

    // —— 收集光标处的建议与提示 ——
    let mut suggestions: Vec<Suggestion> = Vec::new();
    let mut hint = String::new();

    // 逐分支判定 complete
    let branch_done = |branch: &[Node], p: usize| -> bool {
        p >= branch.len() || branch[p..].iter().all(|n| matches!(n, Node::Arg { optional: true, .. }))
    };

    let mut complete = false;
    'outer: for (bi, positions) in &alive {
        let branch = &cmd.branches[*bi];
        for &p in positions {
            if partial.is_empty() && branch_done(branch, p) {
                // 光标位于新 token 起点，且分支已消费完毕
                complete = true;
                break 'outer;
            }
            if !partial.is_empty() && p < branch.len() {
                // 光标正在输入的 token 本身已满足最后一个节点
                let ok = match &branch[p] {
                    Node::Lit(w) => partial == *w,
                    Node::Arg { ty, .. } => validate_arg(*ty, &partial).is_ok(),
                };
                if ok && branch_done(branch, p + 1) {
                    complete = true;
                    break 'outer;
                }
            }
        }
    }

    // —— 收集光标处的建议与提示 ——
    for (bi, positions) in &alive {
        let branch = &cmd.branches[*bi];
        for &p in positions {
            if let Some(node) = branch.get(p) {
                hint = describe_node(node);
                suggestions.extend(node_candidates(node, &partial));
            }
        }
    }

    // 光标所在 token 无任何候选且校验失败 → 实时报错（如拼错的物品/方块 ID）
    let mut errors: Vec<SyntaxError> = Vec::new();
    if suggestions.is_empty() && !partial.is_empty() && active_idx < tokens.len() {
        let any_valid = alive.iter().any(|(bi, positions)| {
            positions.iter().any(|&p| match cmd.branches[*bi].get(p) {
                Some(Node::Lit(w)) => partial == *w,
                // 贪心/子指令节点输入过程中不报错
                Some(Node::Arg { ty, .. })
                    if *ty == ArgType::Greedy || *ty == ArgType::Command =>
                {
                    true
                }
                Some(Node::Arg { ty, .. }) => validate_arg(*ty, &partial).is_ok(),
                None => false,
            })
        });
        if !any_valid {
            let mut expected: Vec<String> = Vec::new();
            let mut any_node = false;
            for (bi, positions) in &alive {
                for &p in positions {
                    if let Some(node) = cmd.branches[*bi].get(p) {
                        any_node = true;
                        let d = match node {
                            Node::Lit(w) => format!("子指令“{w}”"),
                            Node::Arg { ty, .. } => describe(*ty).to_string(),
                        };
                        if !expected.contains(&d) {
                            expected.push(d);
                        }
                    }
                }
            }
            let tok = &tokens[active_idx];
            errors.push(SyntaxError {
                message: if any_node {
                    format!("无法识别的参数“{partial}”，此处应为 {}", expected.join(" 或 "))
                } else {
                    "参数过多".to_string()
                },
                start: tok.start as i32 + body_char_offset as i32,
                end: tok.end as i32 + body_char_offset as i32,
            });
        }
    }

    sort_suggestions(&mut suggestions, &partial);

    AnalysisResult {
        suggestions,
        errors,
        complete,
        hint: if hint.is_empty() { "无更多参数".into() } else { hint },
        usage: build_usage(cmd),
        replace_start: replace_start_abs,
    }
}

fn describe_node(node: &Node) -> String {
    match node {
        Node::Lit(w) => format!("子指令：{w}"),
        Node::Arg { ty, .. } => describe(*ty).to_string(),
    }
}

// ─────────────────────────── execute 专用解析 ───────────────────────────

const EXECUTE_KEYWORDS: &[(&str, &str)] = &[
    ("as", "以某实体的身份执行后续指令"),
    ("at", "以某实体的位置/维度执行后续指令"),
    ("positioned", "在指定坐标执行后续指令"),
    ("if", "条件判断：if entity <目标> / if block <坐标> <方块>"),
    ("run", "执行后续子指令"),
];

fn absolute_span(tok: &Token, body_char_offset: usize) -> (i32, i32) {
    (
        tok.start as i32 + body_char_offset as i32,
        tok.end as i32 + body_char_offset as i32,
    )
}

/// 校验 execute 的子句部分（args[0..n]），返回第一条错误（绝对区间）
fn check_execute_clauses(args: &[Token], body_char_offset: usize) -> Option<SyntaxError> {
    let mut i = 0usize;
    while i < args.len() {
        let (start, end) = absolute_span(&args[i], body_char_offset);
        match args[i].text.as_str() {
            "as" | "at" => {
                let Some(sel) = args.get(i + 1) else {
                    return Some(SyntaxError {
                        message: format!("“{}”之后需要一个目标选择器", args[i].text),
                        start,
                        end,
                    });
                };
                if let Err(e) = validate_arg(ArgType::Selector, &sel.text) {
                    let (s, e2) = absolute_span(sel, body_char_offset);
                    return Some(SyntaxError { message: e, start: s, end: e2 });
                }
                i += 2;
            }
            "positioned" => {
                for k in 1..=3 {
                    let Some(coord) = args.get(i + k) else {
                        return Some(SyntaxError {
                            message: "“positioned”之后需要三个坐标值".into(),
                            start,
                            end,
                        });
                    };
                    if let Err(e) = validate_arg(ArgType::Position, &coord.text) {
                        let (s, e2) = absolute_span(coord, body_char_offset);
                        return Some(SyntaxError { message: e, start: s, end: e2 });
                    }
                }
                i += 4;
            }
            "if" => match args.get(i + 1).map(|t| t.text.as_str()) {
                Some("entity") => {
                    let Some(sel) = args.get(i + 2) else {
                        return Some(SyntaxError {
                            message: "“if entity”之后需要一个目标选择器".into(),
                            start,
                            end,
                        });
                    };
                    if let Err(e) = validate_arg(ArgType::Selector, &sel.text) {
                        let (s, e2) = absolute_span(sel, body_char_offset);
                        return Some(SyntaxError { message: e, start: s, end: e2 });
                    }
                    i += 3;
                }
                Some("block") => {
                    for k in 2..=4 {
                        let Some(coord) = args.get(i + k) else {
                            return Some(SyntaxError {
                                message: "“if block”之后需要三个坐标值".into(),
                                start,
                                end,
                            });
                        };
                        if let Err(e) = validate_arg(ArgType::Position, &coord.text) {
                            let (s, e2) = absolute_span(coord, body_char_offset);
                            return Some(SyntaxError { message: e, start: s, end: e2 });
                        }
                    }
                    let Some(block) = args.get(i + 5) else {
                        return Some(SyntaxError {
                            message: "“if block”之后需要一个方块 ID".into(),
                            start,
                            end,
                        });
                    };
                    if let Err(e) = validate_arg(ArgType::BlockStack, &block.text) {
                        let (s, e2) = absolute_span(block, body_char_offset);
                        return Some(SyntaxError { message: e, start: s, end: e2 });
                    }
                    i += 6;
                }
                _ => {
                    return Some(SyntaxError {
                        message: "“if”之后应为 entity 或 block".into(),
                        start,
                        end,
                    });
                }
            },
            other => {
                return Some(SyntaxError {
                    message: format!("无法识别的 execute 子句“{other}”，可选：as / at / positioned / if / run"),
                    start,
                    end,
                });
            }
        }
    }
    None
}

/// 计算光标位于子句区时的期望参数类型
fn execute_clause_expect(args: &[Token], upto: usize) -> Option<ArgType> {
    let mut i = 0usize;
    while i < upto {
        match args[i].text.as_str() {
            "as" | "at" => {
                if i + 1 >= upto {
                    return Some(ArgType::Selector);
                }
                i += 2;
            }
            "positioned" => {
                for k in 1..=3 {
                    if i + k >= upto {
                        return Some(ArgType::Position);
                    }
                }
                i += 4;
            }
            "if" => match args.get(i + 1).map(|t| t.text.as_str()) {
                Some("entity") => {
                    if i + 2 >= upto {
                        return Some(ArgType::Selector);
                    }
                    i += 3;
                }
                Some("block") => {
                    for k in 2..=4 {
                        if i + k >= upto {
                            return Some(ArgType::Position);
                        }
                    }
                    if i + 5 >= upto {
                        return Some(ArgType::BlockStack);
                    }
                    i += 6;
                }
                _ => return None,
            },
            _ => return None,
        }
    }
    None
}

/// execute 指令的专用分析：子句校验 + 内层子指令递归分析
fn analyze_execute(
    body: &str,
    tokens: &[Token],
    body_char_offset: usize,
    cursor_body: usize,
    replace_start_abs: i32,
) -> AnalysisResult {
    let usage = "/execute as <target> run <command>".to_string();
    let args = &tokens[1..];

    // 最后一个 run 关键字
    let run_idx = args.iter().rposition(|t| t.text == "run");

    // 光标位于 run 之后的内层子指令区域 → 递归分析
    if let Some(ri) = run_idx {
        let run_tok = &args[ri];
        if cursor_body > run_tok.start {
            // 子句部分校验
            if let Some(err) = check_execute_clauses(&args[..ri], body_char_offset) {
                return AnalysisResult {
                    suggestions: Vec::new(),
                    errors: vec![err],
                    complete: false,
                    hint: String::new(),
                    usage,
                    replace_start: replace_start_abs,
                };
            }
            // 内层子指令（从 run 之后开始）
            let slice_start = run_tok.end + 1;
            let slice: String = body.chars().skip(slice_start).collect();
            let inner_cursor = cursor_body.saturating_sub(slice_start);
            let inner = analyze(slice, inner_cursor as i32);

            // 内层结果坐标平移到绝对位置
            let offset = slice_start + body_char_offset;
            let errors = inner
                .errors
                .into_iter()
                .map(|mut e| {
                    e.start += offset as i32;
                    e.end += offset as i32;
                    e
                })
                .collect::<Vec<_>>();
            let suggestions = inner.suggestions;

            return AnalysisResult {
                suggestions,
                errors,
                complete: inner.complete,
                hint: inner.hint,
                usage,
                replace_start: if inner.replace_start >= 0 {
                    inner.replace_start + offset as i32
                } else {
                    replace_start_abs
                },
            };
        }
    }

    // 光标位于子句区域
    let mut errors: Vec<SyntaxError> = Vec::new();
    let mut suggestions: Vec<Suggestion> = Vec::new();
    let mut hint = "execute 子句".to_string();

    let active = locate_cursor(args, cursor_body, body);
    // 排序要用到输入片段，先取出来（`active` 随后会被 match 消费）
    let query = active
        .as_ref()
        .map(|(_, p, _)| p.clone())
        .unwrap_or_default();

    match active {
        Some((idx, partial, _rs)) => {
            if let Some(err) = check_execute_clauses(&args[..idx], body_char_offset) {
                errors.push(err);
            }
            match execute_clause_expect(args, idx) {
                Some(ty) => {
                    hint = describe(ty).to_string();
                    suggestions.extend(node_candidates(&arg("x", ty), &partial));
                }
                None => {
                    hint = "execute 子句".to_string();
                    for (kw, d) in EXECUTE_KEYWORDS {
                        if match_score(kw, &partial).is_some() {
                            suggestions.push(Suggestion {
                                insert: kw.to_string(),
                                label: kw.to_string(),
                                detail: d.to_string(),
                                append_space: true,
                            });
                        }
                    }
                }
            }
        }
        None => {
            // 光标在新 token 起点
            let next_is_arg = match execute_clause_expect(args, args.len()) {
                Some(ty) => {
                    hint = describe(ty).to_string();
                    suggestions.extend(node_candidates(&arg("x", ty), ""));
                    true
                }
                None => false,
            };
            if !next_is_arg {
                for (kw, d) in EXECUTE_KEYWORDS {
                    suggestions.push(Suggestion {
                        insert: kw.to_string(),
                        label: kw.to_string(),
                        detail: d.to_string(),
                        append_space: true,
                    });
                }
            }
        }
    }

    sort_suggestions(&mut suggestions, &query);

    AnalysisResult {
        suggestions,
        errors,
        complete: false,
        hint,
        usage,
        replace_start: replace_start_abs,
    }
}

/// 找出第一个匹配失败的 token 并生成精确错误
fn first_error_result(
    cmd: &Cmd,
    tokens: &[Token],
    body_char_offset: usize,
    replace_start_abs: i32,
    max_n: usize,
) -> AnalysisResult {
    for n in 1..=max_n {
        let consumed = &tokens[..n];
        let alive: Vec<&Vec<Node>> = cmd
            .branches
            .iter()
            .filter(|b| !advance(b, consumed, n).is_empty())
            .collect();
        if !alive.is_empty() {
            continue;
        }
        // tokens[n-1] 是失败位置
        let tok = &tokens[n - 1];
        let start = tok.start as i32 + body_char_offset as i32;
        let end = tok.end as i32 + body_char_offset as i32;
        // 从所有分支中收集 n-1 位置可能的节点，生成错误信息
        let mut expected: Vec<String> = Vec::new();
        let mut excess = true;
        for branch in &cmd.branches {
            let positions = advance(branch, &tokens[..n - 1], n - 1);
            if positions.is_empty() {
                continue;
            }
            excess = false;
            for &p in &positions {
                if p >= branch.len() {
                    continue;
                }
                match &branch[p] {
                    Node::Lit(w) => expected.push(format!("子指令“{w}”")),
                    Node::Arg { ty, .. } => {
                        let d = describe(*ty);
                        if !expected.iter().any(|e| e == d) {
                            expected.push(d.to_string());
                        }
                    }
                }
            }
        }
        let message = if excess || expected.is_empty() {
            "参数过多".to_string()
        } else {
            format!("第 {n} 个参数错误：此处应为 {}", expected.join(" 或 "))
        };
        return AnalysisResult {
            suggestions: Vec::new(),
            errors: vec![SyntaxError { message, start, end }],
            complete: false,
            hint: String::new(),
            usage: build_usage(cmd),
            replace_start: replace_start_abs,
        };
    }
    AnalysisResult {
        suggestions: Vec::new(),
        errors: vec![SyntaxError {
            message: "无法解析该指令".into(),
            start: 0,
            end: 0,
        }],
        complete: false,
        hint: String::new(),
        usage: build_usage(cmd),
        replace_start: replace_start_abs,
    }
}

// ─────────────────────────── 执行 ───────────────────────────

fn semantic_check(cmd_name: &str, args: &[String]) -> Result<(), String> {
    match cmd_name {
        "give" | "clear" => {
            if let Some(count) = args.get(2) {
                let c: i64 = count.parse().unwrap_or(1);
                if c < 1 {
                    return Err("数量必须 ≥ 1".into());
                }
                if c > 6400 {
                    return Err("数量超出上限（6400）".into());
                }
            }
            Ok(())
        }
        "enchant" => {
            if let Some(level) = args.get(2) {
                let l: i64 = level.parse().unwrap_or(1);
                if !(1..=5).contains(&l) {
                    return Err("附魔等级必须在 1 - 5 之间".into());
                }
            }
            Ok(())
        }
        "effect" => {
            if args.len() >= 4 && args[0] == "give" {
                let secs: i64 = args[3].parse().unwrap_or(30);
                if secs < 1 || secs > 1000000 {
                    return Err("持续时间为 1 - 1000000 秒".into());
                }
                if let Some(amp) = args.get(4) {
                    let a: i64 = amp.parse().unwrap_or(0);
                    if !(0..=255).contains(&a) {
                        return Err("效果等级必须在 0 - 255 之间".into());
                    }
                }
            }
            Ok(())
        }
        "damage" => {
            if let Some(amount) = args.get(1) {
                let a: f64 = amount.parse().unwrap_or(0.0);
                if a <= 0.0 || a > 3.4e38 {
                    return Err("伤害值必须大于 0".into());
                }
            }
            Ok(())
        }
        "bossbar" => {
            if args.len() >= 4 && args[0] == "set" && (args[2] == "value" || args[2] == "max") {
                let v: i64 = args[3].parse().unwrap_or(0);
                if v < 0 {
                    return Err("血条数值不能为负".into());
                }
            }
            Ok(())
        }
        "worldborder" => {
            if (args[0] == "set" || args[0] == "add") && !args.is_empty() {
                let d: i64 = args.get(1).and_then(|v| v.parse().ok()).unwrap_or(0);
                if d <= 1 {
                    return Err("边界尺寸必须大于 1 格".into());
                }
            }
            Ok(())
        }
        "item" => {
            // 末尾若为整数且参数充足，则是可选的数量参数
            if args.len() >= 6 {
                if let Some(last) = args.last() {
                    if let Ok(c) = last.parse::<i64>() {
                        if !(1..=64).contains(&c) {
                            return Err("物品数量必须在 1 - 64 之间".into());
                        }
                    }
                }
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn execute_message(cmd_name: &str, args: &[String]) -> String {
    // 展示用的参数：ID / 选择器 / 枚举关键字都翻成中文。
    // 逻辑判断仍然用原始 `args`（`add`、`set` 这类子指令字面量不会被翻译）。
    let cn: Vec<String> = args.iter().map(|a| reg::localize(a)).collect();

    match cmd_name {
        "gamemode" => {
            let mode = match args[0].as_str() {
                "survival" => "生存模式",
                "creative" => "创造模式",
                "adventure" => "冒险模式",
                _ => "旁观模式",
            };
            match args.get(1) {
                Some(_) => format!("已将 {} 的游戏模式切换为{mode}", cn[1]),
                None => format!("已将自己的游戏模式切换为{mode}"),
            }
        }
        "give" => {
            let count = args.get(2).and_then(|c| c.parse::<i64>().ok()).unwrap_or(1);
            // 只显示物品的中文名，附加数据用摘要说明，不把原始组件原样倒出来
            let (id, data) = split_item_stack(&args[1]);
            let item = reg::localize(id);
            match data.and_then(summarize_item_data) {
                Some(summary) => {
                    format!("已将 {count} 个【{item}】给予 {}，附带：{summary}", cn[0])
                }
                None => format!("已将 {count} 个【{item}】给予 {}", cn[0]),
            }
        }
        "tp" | "teleport" => {
            // 首个参数是坐标（数字 / ~ / ^）就是"传送到某坐标"，否则是"传送某个目标"
            let first_is_coord = args[0].starts_with('~')
                || args[0].starts_with('^')
                || args[0].parse::<f64>().is_ok();
            if first_is_coord {
                format!("已传送到坐标 ({}, {}, {})", args[0], args[1], args[2])
            } else {
                match args.len() {
                    1 => format!("已将【{}】传送到指令执行者身边", cn[0]),
                    2 => format!("已将【{}】传送到【{}】的位置", cn[0], cn[1]),
                    _ => format!(
                        "已将【{}】传送到坐标 ({}, {}, {})",
                        cn[0], args[1], args[2], args[3]
                    ),
                }
            }
        }
        "effect" => {
            if args[0] == "clear" {
                match (args.get(1), args.get(2)) {
                    (Some(_), Some(_)) => format!("已清除 {} 身上的【{}】效果", cn[1], cn[2]),
                    (Some(_), None) => format!("已清除 {} 身上的所有状态效果", cn[1]),
                    (None, _) => "已清除自己身上的所有状态效果".into(),
                }
            } else {
                let secs = args.get(3).cloned().unwrap_or_else(|| "30".into());
                let amp = args.get(4).cloned().unwrap_or_else(|| "0".into());
                let level = amp.parse::<i64>().map(|a| a + 1).unwrap_or(1);
                format!(
                    "已给予 {} 状态效果【{}】，持续 {secs} 秒，等级 {level}",
                    cn[1], cn[2]
                )
            }
        }
        "enchant" => {
            let level = args.get(2).cloned().unwrap_or_else(|| "1".into());
            format!("已为 {} 手持的物品附上【{}】{level} 级附魔", cn[0], cn[1])
        }
        "summon" => {
            let place = if args.len() >= 4 {
                format!("已在坐标 ({}, {}, {})", args[1], args[2], args[3])
            } else {
                "已在指令执行者的位置".to_string()
            };
            // 末尾的 `{...}` 是实体 NBT
            let data = args
                .last()
                .filter(|a| a.starts_with('{'))
                .and_then(|a| summarize_item_data(a));
            match data {
                Some(summary) => format!("{place} 生成【{}】，{summary}", cn[0]),
                None => format!("{place} 生成【{}】", cn[0]),
            }
        }
        "setblock" => format!(
            "已将坐标 ({}, {}, {}) 的方块设置为【{}】",
            args[0], args[1], args[2], cn[3]
        ),
        "fill" => {
            let region = format!(
                "({}, {}, {}) 到 ({}, {}, {})",
                args[0], args[1], args[2], args[3], args[4], args[5]
            );
            match args.get(7) {
                Some(_) => format!("已将{region} 填充为【{}】，方式：{}", cn[6], cn[7]),
                None => format!("已将{region} 填充为【{}】", cn[6]),
            }
        }
        "clone" => {
            let source = format!(
                "({}, {}, {}) 到 ({}, {}, {})",
                args[0], args[1], args[2], args[3], args[4], args[5]
            );
            let target = format!("({}, {}, {})", args[6], args[7], args[8]);
            // 第 10、11 个参数依次是过滤模式与复制方式，都可省略
            let mut tail = String::new();
            if args.get(9).is_some() {
                tail.push_str(&format!("，过滤：{}", cn[9]));
            }
            if args.get(10).is_some() {
                tail.push_str(&format!("，方式：{}", cn[10]));
            }
            format!("已将{source} 的方块克隆到{target}{tail}")
        }
        "kill" => match args.first() {
            Some(_) => format!("已杀死{}", cn[0]),
            None => "已杀死自己".into(),
        },
        "clear" => match args.first() {
            Some(_) => {
                let item = match args.get(1) {
                    Some(_) => format!("【{}】", cn[1]),
                    None => "物品".to_string(),
                };
                let count = args.get(2).cloned().unwrap_or_else(|| "全部".into());
                format!("已从 {} 的物品栏中清除了 {item} {count} 件", cn[0])
            }
            None => "已清空自己的物品栏".into(),
        },
        "time" => match args[0].as_str() {
            "set" => {
                let label = match args[1].as_str() {
                    "day" => "白天（1000 tick）",
                    "noon" => "正午（6000 tick）",
                    "night" => "夜晚（13000 tick）",
                    "midnight" => "午夜（18000 tick）",
                    other => other,
                };
                format!("已将时间设置为{label}")
            }
            "add" => format!("已将时间快进 {} tick", args[1]),
            _ => format!("当前{}：{}", cn[1], args[1]),
        },
        "weather" => {
            let label = match args[0].as_str() {
                "clear" => "晴天",
                "rain" => "雨天",
                _ => "雷暴",
            };
            match args.get(1) {
                Some(d) => format!("已将天气设置为{label}，持续 {d} 秒"),
                None => format!("已将天气设置为{label}"),
            }
        }
        "difficulty" => {
            let label = match args[0].as_str() {
                "peaceful" => "和平",
                "easy" => "简单",
                "normal" => "普通",
                _ => "困难",
            };
            format!("已将游戏难度设置为{label}")
        }
        "say" => format!("[服务器] {}", args.join(" ")),
        "me" => format!("* 指令执行者 {}", args.join(" ")),
        "tellraw" => format!("已向 {} 发送原始 JSON 消息：{}", cn[0], args[1]),
        "title" => {
            if args.get(1).map(|s| s.as_str()) == Some("times") {
                format!(
                    "已设置标题时长：淡入 {} tick，停留 {} tick，淡出 {} tick",
                    args[2], args[3], args[4]
                )
            } else {
                format!("已向 {} 显示【{}】：{}", cn[0], cn[1], args[2..].join(" "))
            }
        }
        "xp" | "experience" => {
            let levels = args.get(3).map(|s| s.as_str()).unwrap_or("points") == "levels";
            match args[0].as_str() {
                "set" => format!(
                    "已将 {} 的经验{}设为 {}",
                    cn[1],
                    if levels { "等级" } else { "点数" },
                    args[2]
                ),
                "query" => format!(
                    "{} 当前有 {} {}（模拟）",
                    cn[1],
                    args[2],
                    if levels { "级" } else { "点经验" }
                ),
                _ => format!(
                    "已给予 {} {} {}",
                    cn[1],
                    args[2],
                    if levels { "级经验值" } else { "点经验值" }
                ),
            }
        }
        "spawnpoint" => match args.first() {
            Some(_) => {
                let place = if args.len() >= 4 {
                    format!("坐标 ({}, {}, {})", args[1], args[2], args[3])
                } else {
                    "当前坐标".to_string()
                };
                let angle = match args.get(4) {
                    Some(_) => format!("，朝向 {}", args[4]),
                    None => String::new(),
                };
                format!("已将 {} 的出生点设置为{place}{angle}", cn[0])
            }
            None => "已将自己的出生点设置为当前坐标".into(),
        },
        "gamerule" => match args.get(1) {
            Some(_) => format!("游戏规则 {} 已更新为 {}", cn[0], cn[1]),
            None => format!("游戏规则 {} 当前值：默认", cn[0]),
        },
        "kick" => match args.get(1) {
            Some(r) => format!("已将 {} 踢出服务器，原因：{r}", cn[0]),
            None => format!("已将 {} 踢出服务器", cn[0]),
        },
        "ban" => match args.get(1) {
            Some(r) => format!("已封禁 {}，原因：{r}", cn[0]),
            None => format!("已封禁 {}", cn[0]),
        },
        "op" => format!("已将 {} 提升为服务器管理员", cn[0]),
        "deop" => format!("已撤销 {} 的管理员权限", cn[0]),
        "seed" => "世界种子：-4738250169295530411（模拟）".into(),
        "list" => "在线玩家（2/20）：Alex、Steve".into(),
        "help" => "可用指令：/gamemode /give /tp /effect /enchant /summon /setblock /fill /clone /kill /clear /time /weather /difficulty /tellraw /title /xp /gamerule /say /execute /scoreboard /data /locate /tag /bossbar /team /playsound /item /worldborder /attribute /damage /ride /help 等，输入 / 可查看全部".into(),
        // ───────────── 必加 ─────────────
        "msg" | "tell" | "w" => format!("已向 {} 发送私信：{}", cn[0], args[1..].join(" ")),
        "tag" => match args[1].as_str() {
            "add" => format!("已为 {} 添加标签【{}】", cn[0], args[2]),
            "remove" => format!("已移除 {} 的标签【{}】", cn[0], args[2]),
            _ => format!(
                "{} 身上的标签：{}",
                cn[0],
                if args.len() > 3 {
                    args[3..].join("、")
                } else {
                    "（无）".into()
                }
            ),
        },
        "data" => match args[0].as_str() {
            "merge" => {
                if args[1] == "entity" {
                    format!("已把 NBT 数据 {} 合并到 {}", args[3], cn[2])
                } else {
                    format!(
                        "已把 NBT 数据 {} 合并到坐标 ({}, {}, {}) 处的方块",
                        args[5], args[2], args[3], args[4]
                    )
                }
            }
            _ => {
                if args[1] == "entity" {
                    format!("{} 的 NBT 数据：{{Health:20f, ...}}（模拟）", cn[2])
                } else {
                    format!(
                        "坐标 ({}, {}, {}) 处方块的 NBT 数据：{{Items:[]}}（模拟）",
                        args[2], args[3], args[4]
                    )
                }
            }
        },
        "locate" => {
            if args[0] == "structure" {
                format!(
                    "已定位到最近的【{}】：X: 128, Y: 70, Z: -256（模拟）",
                    cn[1]
                )
            } else {
                format!(
                    "最近的生物群系【{}】：X: 64, Y: 70, Z: 192（模拟）",
                    cn[1]
                )
            }
        }
        "setworldspawn" => {
            if args.len() >= 3 {
                format!("已将世界出生点设置为坐标 ({}, {}, {})", args[0], args[1], args[2])
            } else {
                "已将世界出生点设置为当前位置".into()
            }
        }
        "scoreboard" => {
            if args[0] == "objectives" {
                match args[1].as_str() {
                    "add" => match args.get(4) {
                        Some(_) => format!(
                            "已添加记分板目标【{}】，判据：{}，显示名：{}",
                            args[2],
                            cn[3],
                            args[4..].join(" ")
                        ),
                        None => format!("已添加记分板目标【{}】，判据：{}", args[2], cn[3]),
                    },
                    "remove" => format!("已移除记分板目标【{}】", args[2]),
                    "setdisplay" => match args.get(3) {
                        Some(_) => format!("已在【{}】槽位显示目标【{}】", cn[2], args[3]),
                        None => format!("已清除【{}】槽位的显示", cn[2]),
                    },
                    "modify" => {
                        let name = format!("【{}】", args[2]);
                        match args[3].as_str() {
                            "displayname" => format!(
                                "已将记分板目标{name}的显示名改为 {}",
                                args[4..].join(" ")
                            ),
                            "rendertype" => {
                                format!("已将记分板目标{name}的数字渲染方式改为{}", cn[4])
                            }
                            _ => format!(
                                "已将记分板目标{name}的数字格式改为{}",
                                cn.get(4).cloned().unwrap_or_default()
                            ),
                        }
                    }
                    _ => "记分板目标：kills、deaths、coins（模拟）".into(),
                }
            } else {
                match args[1].as_str() {
                    "list" => match args.get(2) {
                        Some(_) => format!("{} 的记分板：kills=10、coins=128（模拟）", cn[2]),
                        None => "所有玩家的记分板：kills=10、coins=128（模拟）".into(),
                    },
                    "get" => format!("{} 的【{}】分数为 10（模拟）", cn[2], args[3]),
                    "set" => format!("已将 {} 的【{}】分数设置为 {}", cn[2], args[3], args[4]),
                    "add" => format!("已将 {} 的【{}】分数增加了 {}", cn[2], args[3], args[4]),
                    "remove" => format!("已将 {} 的【{}】分数减少了 {}", cn[2], args[3], args[4]),
                    "reset" => match args.get(3) {
                        Some(_) => format!("已重置 {} 的【{}】分数", cn[2], args[3]),
                        None => format!("已重置 {} 的所有分数", cn[2]),
                    },
                    "enable" => format!("已启用 {} 的触发器【{}】", cn[2], args[3]),
                    "operation" => format!(
                        "已执行运算：{} 的【{}】 {} {} 的【{}】",
                        cn[2], args[3], args[4], cn[5], args[6]
                    ),
                    "display" => {
                        if args[2] == "name" {
                            format!(
                                "已将 {} 的【{}】显示名改为 {}",
                                cn[3],
                                args[4],
                                args[5..].join(" ")
                            )
                        } else {
                            format!(
                                "已将 {} 的【{}】数字格式改为{}",
                                cn[3],
                                args[4],
                                cn.get(5).cloned().unwrap_or_default()
                            )
                        }
                    }
                    _ => "已执行记分板指令".into(),
                }
            }
        }
        // ───────────── 推荐追加 ─────────────
        "bossbar" => {
            if args[0] == "add" {
                format!("已创建 Boss 血条【{}】，名称：{}", args[1], args[2])
            } else if args[0] == "remove" {
                format!("已移除 Boss 血条【{}】", args[1])
            } else if args[0] == "list" {
                "Boss 血条：custom:hp、custom:energy（模拟）".into()
            } else if args[0] == "get" {
                format!(
                    "Boss 血条【{}】的 {}：5（模拟）",
                    args[1],
                    cn.get(2).cloned().unwrap_or_else(|| "当前值".into())
                )
            } else {
                format!("已将血条【{}】的{}设置为 {}", args[1], cn[2], args[3])
            }
        }
        "team" => match args[0].as_str() {
            "list" => match args.get(1) {
                Some(_) => format!("队伍【{}】的成员：Alex、Steve（模拟）", args[1]),
                None => "队伍：red、blue、builders（模拟）".into(),
            },
            "add" => format!(
                "已创建队伍【{}】{}",
                args[1],
                args.get(2).map(|d| format!("，显示名：{d}")).unwrap_or_default()
            ),
            "remove" => format!("已移除队伍【{}】", args[1]),
            "empty" => format!("已清空队伍【{}】的所有成员", args[1]),
            "join" => format!(
                "已将 {} 加入队伍【{}】",
                cn.get(2).cloned().unwrap_or_else(|| "自己".into()),
                args[1]
            ),
            "leave" => format!("已将 {} 移出所在队伍", cn[1]),
            _ => format!("已将队伍【{}】的 {} 修改为 {}", args[1], cn[2], cn[3]),
        },
        "playsound" => {
            let mut base = format!("已向 {} 播放音效【{}】，来源：{}", cn[2], cn[0], cn[1]);
            if args.len() >= 7 {
                base = format!(
                    "{base}，音量 {}，音调 {}",
                    args[6],
                    args.get(7).cloned().unwrap_or_else(|| "1".into())
                );
            }
            if let Some(v) = args.get(8) {
                base = format!("{base}，最小音量 {v}");
            }
            base
        }
        "stopsound" => match args.get(2) {
            Some(_) => format!("已停止 {} 的{}来源音效【{}】", cn[0], cn[1], args[2]),
            None => match args.get(1) {
                Some(_) => format!("已停止 {} 的{}来源全部音效", cn[0], cn[1]),
                None => format!("已停止 {} 的全部音效", cn[0]),
            },
        },
        "item" => {
            if args[1] == "entity" {
                let count = args.get(5).cloned().unwrap_or_else(|| "1".into());
                format!(
                    "已将 {} 的【{}】槽位替换为【{}】×{count}",
                    cn[2], args[3], cn[4]
                )
            } else {
                let count = args.get(7).cloned().unwrap_or_else(|| "1".into());
                format!(
                    "已将坐标 ({}, {}, {}) 处方块的【{}】槽位替换为【{}】×{count}",
                    args[2], args[3], args[4], args[5], cn[6]
                )
            }
        }
        "worldborder" => match args[0].as_str() {
            "get" => "当前世界边界：1000 × 1000 格，中心 (0, 0)（模拟）".into(),
            "set" | "add" => match args.get(2) {
                Some(s) => format!("世界边界将在 {s} 秒内调整为 {} 格", args[1]),
                None => format!("世界边界已调整为 {} 格", args[1]),
            },
            "center" => format!("世界边界中心已设置为 ({}, {})", args[1], args[2]),
            _ => format!("边界{} 已设置为 {}", cn[1], args[2]),
        },
        "attribute" => match args[2].as_str() {
            "get" => format!("{} 的【{}】：20.0（模拟）", cn[0], args[1]),
            "base" => {
                if args[3] == "get" {
                    format!("{} 的【{}】基础值为 20.0（模拟）", cn[0], args[1])
                } else {
                    format!("已将 {} 的【{}】基础值设置为 {}", cn[0], args[1], args[4])
                }
            }
            _ => {
                if args[3] == "add" {
                    format!(
                        "已为 {} 添加属性修饰符【{}】：{} {}",
                        cn[0], args[5], cn[6], args[7]
                    )
                } else {
                    format!("已移除 {} 的属性修饰符【{}】", cn[0], args[5])
                }
            }
        },
        // ───────────── 服务器管理 ─────────────
        "save-all" => {
            if args.first().map(|s| s.as_str()) == Some("flush") {
                "已保存世界（同步写入完成）".into()
            } else {
                "已保存世界（异步写入中）".into()
            }
        }
        "stop" => "服务器正在关闭，所有玩家将被断开连接…".into(),
        "pardon" | "unban" => format!("已解封 {}", cn[0]),
        "banlist" => {
            if args.first().map(|s| s.as_str()) == Some("ips") {
                "IP 封禁列表：192.168.1.7（模拟）".into()
            } else {
                "封禁列表（2）：Steve（作弊）、Alex（外挂）（模拟）".into()
            }
        }
        // ───────────── 其他 ─────────────
        "clearspawnpoint" => match args.first() {
            Some(_) => format!("已清除 {} 的出生点", cn[0]),
            None => "已清除自己的出生点".into(),
        },
        "damage" => {
            let base = match args.get(2) {
                Some(_) => format!("已对 {} 造成 {} 点{}伤害", cn[0], args[1], cn[2]),
                None => format!("已对 {} 造成 {} 点伤害", cn[0], args[1]),
            };
            // 尾部：`at <坐标>` 或 `by <实体> [from <起因>]`
            match args.get(3).map(|s| s.as_str()) {
                Some("at") => format!(
                    "{base}，伤害来源位于坐标 ({}, {}, {})",
                    args[4], args[5], args[6]
                ),
                Some("by") => match args.get(5) {
                    Some(_) => format!("{base}，伤害来源为 {}，起因是 {}", cn[4], cn[6]),
                    None => format!("{base}，伤害来源为 {}", cn[4]),
                },
                _ => base,
            }
        }
        "ride" => {
            if args[1] == "mount" {
                format!("已让 {} 骑上【{}】", cn[0], cn[2])
            } else {
                format!("已让 {} 从坐骑上下来", cn[0])
            }
        }
        "spectate" => match args.first() {
            Some(_) => format!("已开始旁观【{}】", cn[0]),
            None => "已停止旁观".into(),
        },
        // ───────────── 第二批 ─────────────
        "advancement" => {
            let verb = if args[0] == "grant" { "授予" } else { "撤销" };
            if args.get(2).map(|s| s.as_str()) == Some("only") {
                format!("已{verb} {} 的进度【{}】", cn[1], cn[3])
            } else {
                format!("已{verb} {} 的全部进度", cn[1])
            }
        }
        "defaultgamemode" => {
            let label = match args[0].as_str() {
                "survival" => "生存模式",
                "creative" => "创造模式",
                "adventure" => "冒险模式",
                _ => "旁观模式",
            };
            format!("默认游戏模式已设置为{label}")
        }
        "function" => format!("已执行数据包函数【{}】（模拟）", args[0]),
        "loot" => {
            if args[0] == "give" {
                format!("已将战利品表【{}】的产出给予 {}", args[2], cn[1])
            } else if args[0] == "spawn" {
                format!(
                    "已在坐标 ({}, {}, {}) 生成战利品表【{}】的产出",
                    args[1], args[2], args[3], args[4]
                )
            } else if args[1] == "entity" {
                format!(
                    "已将 {} 的【{}】槽位替换为战利品表【{}】的产出",
                    cn[2], args[3], args[4]
                )
            } else {
                format!(
                    "已将坐标 ({}, {}, {}) 处方块的【{}】槽位替换为战利品表【{}】的产出",
                    args[2], args[3], args[4], args[5], args[6]
                )
            }
        }
        "particle" => {
            // 三种写法：<粒子> <目标> / <粒子> <坐标> / <粒子> <坐标> <扩散> <速度> <数量>
            match args.len() {
                2 => format!("已在 {} 的位置生成【{}】粒子", cn[1], cn[0]),
                4 => format!(
                    "已在坐标 ({}, {}, {}) 生成【{}】粒子",
                    args[1], args[2], args[3], cn[0]
                ),
                _ => format!(
                    "已在坐标 ({}, {}, {}) 生成 {} 个【{}】粒子，扩散 ({}, {}, {})，速度 {}",
                    args[1],
                    args[2],
                    args[3],
                    args[args.len() - 2],
                    cn[0],
                    args[4],
                    args[5],
                    args[6],
                    args[7]
                ),
            }
        }
        "place" => {
            if args[0] == "feature" {
                if args.len() >= 5 {
                    format!(
                        "已在坐标 ({}, {}, {}) 放置【{}】地物",
                        args[2], args[3], args[4], cn[1]
                    )
                } else {
                    format!("已在当前位置放置【{}】地物", cn[1])
                }
            } else if args[0] == "structure" {
                format!(
                    "已在坐标 ({}, {}, {}) 放置【{}】结构",
                    args[2], args[3], args[4], cn[1]
                )
            } else {
                format!(
                    "已在坐标 ({}, {}, {}) 放置拼图池【{}】",
                    args[5], args[6], args[7], args[1]
                )
            }
        }
        "recipe" => {
            if args[0] == "give" {
                format!("已为 {} 解锁配方【{}】", cn[1], args[2])
            } else {
                format!("已从 {} 处移除配方【{}】", cn[1], args[2])
            }
        }
        "reload" => "已重新加载全部数据包（模拟）".into(),
        "schedule" => {
            if args[0] == "clear" {
                format!("已清除函数【{}】的定时执行计划", args[1])
            } else {
                let delay: i64 = args[2].parse().unwrap_or(0);
                format!("已安排在 {delay} tick 后执行函数【{}】", args[1])
            }
        }
        "spreadplayers" => format!(
            "已将 {} 随机分散到 ({}, {}) 附近，间距 {}，最大半径 {}",
            cn[5], args[0], args[1], args[2], args[3]
        ),
        "teammsg" | "tm" => format!("[队伍] {}", args.join(" ")),
        "tick" => match args[0].as_str() {
            "query" => "当前 tick：1200，速率 20.0/s（模拟）".into(),
            "rate" => format!("已将服务器速率调整为 {} tick/s", args[1]),
            "sprint" => format!("已进入冲刺模式，将在 {} tick 内全速运行", args[1]),
            "step" => match args.get(1) {
                Some(t) => format!("已步进 {t} tick"),
                None => "已步进 1 tick".into(),
            },
            "freeze" => "服务器 tick 已冻结".into(),
            _ => "服务器 tick 已恢复运行".into(),
        },
        "trigger" => match args.get(2) {
            Some(_) => format!(
                "触发器【{}】已{} {}",
                args[0],
                if args[1] == "add" { "增加" } else { "设置为" },
                args[2]
            ),
            None => format!("触发器【{}】已触发", args[0]),
        },
        "version" => "服务器版本：Minecraft 26.3（模拟）".into(),
        "forceload" => match args[0].as_str() {
            "add" => {
                if args.len() >= 5 {
                    format!(
                        "已强制加载区块 ({}, {}) 到 ({}, {})",
                        args[1], args[2], args[3], args[4]
                    )
                } else {
                    format!("已强制加载区块 ({}, {})", args[1], args[2])
                }
            }
            "remove" => {
                if args.get(1).map(|s| s.as_str()) == Some("all") {
                    "已取消全部强制加载的区块".into()
                } else if args.len() >= 5 {
                    format!(
                        "已取消强制加载区块 ({}, {}) 到 ({}, {})",
                        args[1], args[2], args[3], args[4]
                    )
                } else {
                    format!("已取消强制加载区块 ({}, {})", args[1], args[2])
                }
            }
            _ => match args.get(1) {
                Some(_) => "该区块当前已被强制加载（模拟）".into(),
                None => "强制加载区块数：4（模拟）".into(),
            },
        },
        "fillbiome" => format!(
            "已将区域 ({}, {}) 到 ({}, {}) 的生物群系填充为【{}】",
            args[0], args[1], args[2], args[3], cn[4]
        ),
        "random" => match args[0].as_str() {
            "reset" => format!("已重置随机序列【{}】", args[1]),
            _ => format!("随机数（范围 {}）：7（模拟）", args[1]),
        },
        "return" => format!("函数返回值：{}", args[0]),
        "rotate" => match args.get(3) {
            Some(d) => format!(
                "已在 {d} tick 内将 {} 旋转到偏航角 {}、俯仰角 {}",
                cn[0], args[1], args[2]
            ),
            None => format!("已将 {} 旋转到偏航角 {}、俯仰角 {}", cn[0], args[1], args[2]),
        },
        "waypoint" => {
            if args[0] == "list" {
                "路点：home (0, 64, 0)、base (128, 70, -64)（模拟）".into()
            } else {
                format!("已修改路点【{}】的{}为 {}", args[1], cn[2], args[3])
            }
        }
        "stopwatch" => match args[0].as_str() {
            "create" => format!("已创建计时器【{}】", args[1]),
            "start" => format!("计时器【{}】已开始计时", args[1]),
            "stop" => format!("计时器【{}】已停止：3.52 秒（模拟）", args[1]),
            "query" => format!("计时器【{}】：1.20 秒（模拟）", args[1]),
            _ => "计时器：run1、parkour（模拟）".into(),
        },
        "datapack" => match args[0].as_str() {
            "enable" => format!("已启用数据包【{}】", args[1]),
            "disable" => format!("已禁用数据包【{}】", args[1]),
            _ => "可用数据包：vanilla、file/my_pack（模拟）".into(),
        },
        "dialog" => {
            if args[0] == "show" {
                format!("已向 {} 显示对话框【{}】", cn[1], args[2])
            } else {
                format!("已清除 {} 的对话框", cn[1])
            }
        }
        "swing" => match args.get(1) {
            Some(_) => format!("{} 挥动了{}", cn[0], cn[1]),
            None => match args.first() {
                Some(_) => format!("{} 挥动了主手", cn[0]),
                None => "指令执行者挥动了主手".into(),
            },
        },
        "fetchprofile" => format!("已获取 {} 的玩家档案（模拟）", cn[0]),
        "posteffect" => {
            if args[0] == "clear" {
                "已清除屏幕后处理效果".into()
            } else {
                format!("已应用后处理效果【{}】", args[0])
            }
        }
        "whitelist" => match args[0].as_str() {
            "on" => "白名单已启用".into(),
            "off" => "白名单已关闭".into(),
            "add" => format!("已将 {} 加入白名单", cn[1]),
            "remove" => format!("已将 {} 移出白名单", cn[1]),
            "reload" => "白名单已重新加载".into(),
            _ => "白名单（2）：Alex、Steve（模拟）".into(),
        },
        "ban-ip" => match args.get(1) {
            Some(r) => format!("已封禁 IP {}，原因：{r}", args[0]),
            None => format!("已封禁 IP {}", args[0]),
        },
        "pardon-ip" => format!("已解封 IP {}", args[0]),
        "setidletimeout" => format!("挂机踢出时间已设置为 {} 分钟", args[0]),
        "save-off" => "已关闭自动保存".into(),
        "save-on" => "已启用自动保存".into(),
        "publish" => match args.first() {
            Some(p) => format!("世界已在端口 {p} 上向局域网开放（模拟）"),
            None => "世界已向局域网开放（模拟）".into(),
        },
        "unpublish" => "已关闭局域网开放".into(),
        "transfer" => match args.get(1) {
            Some(p) => format!("已将玩家转移到 {} 的 {p} 端口（模拟）", args[0]),
            None => format!("已将玩家转移到 {}（模拟）", args[0]),
        },
        "perf" => match args[0].as_str() {
            "start" => "已开始性能记录".into(),
            "stop" => "已停止性能记录并生成报告".into(),
            _ => "已清空性能记录缓存".into(),
        },
        "debug" => match args[0].as_str() {
            "start" => "已开始调试采样".into(),
            "stop" => "已停止调试采样并输出报告".into(),
            _ => "调试报告已生成（模拟）".into(),
        },
        "jfr" => {
            if args[0] == "start" {
                "已开始 JFR 性能记录".into()
            } else {
                "已停止 JFR 性能记录".into()
            }
        }
        "serverpack" => "服务器资源包已生成（模拟）".into(),
        "debugconfig" => format!("调试配置【{}】：当前值 true（模拟）", args[args.len() - 1]),
        "debugpath" => match args.first() {
            Some(a) => format!("寻路路径渲染：已{}", if a == "stop" { "停止" } else { "开始" }),
            None => "已切换寻路路径渲染（模拟）".into(),
        },
        "debugmobspawning" => match args.get(1) {
            Some(c) => format!("生物生成冷却已设置为 {c} tick"),
            None => match args.first() {
                Some(_) => "生物生成数据已重置".into(),
                None => "生物生成调试信息已输出（模拟）".into(),
            },
        },
        "warden_spawn_tracker" => {
            if args[0] == "reset" {
                "监守者生成追踪已重置".into()
            } else {
                format!("监守者生成追踪值已设置为 {}", args[1])
            }
        }
        "spawn_armor_trims" => "已生成全部盔甲纹饰（模拟）".into(),
        "raid" => {
            if args[0] == "stop" {
                format!("已停止 {} 附近的袭击", cn[1])
            } else {
                format!("{} 附近的袭击：当前为第 2 波（模拟）", cn[1])
            }
        }
        "chase" => format!("已开始追踪指令【{}】（开发版）", args[0]),
        "test" => match args[0].as_str() {
            "runall" => "已运行全部游戏测试（模拟）".into(),
            "resetall" => "已重置全部测试结构".into(),
            "clearall" => "已清除全部测试结构".into(),
            _ => format!("已运行测试【{}】", args[1]),
        },
        _ => "指令已执行".into(),
    }
}

/// execute 子指令执行：解析子指令并递归执行
fn execute_execute(args: &[String]) -> ExecutionResult {
    // 找到 run 关键字
    let run_idx = match args.iter().rposition(|a| a == "run") {
        Some(i) => i,
        None => return ExecutionResult { success: false, message: "缺少 run 子指令".into() },
    };
    let inner: String = args[run_idx + 1..].join(" ");
    if inner.trim().is_empty() {
        return ExecutionResult { success: false, message: "缺少 run 后的子指令".into() };
    }

    // 组装上下文描述（选择器等参数同样翻成中文）
    let arg_cn = |k: usize| reg::localize(args.get(k).map(|s| s.as_str()).unwrap_or(""));
    let mut clauses: Vec<String> = Vec::new();
    let mut i = 0;
    while i < run_idx {
        match args[i].as_str() {
            "as" => {
                clauses.push(format!("以 {} 的身份", arg_cn(i + 1)));
                i += 2;
            }
            "at" => {
                clauses.push(format!("在 {} 的位置", arg_cn(i + 1)));
                i += 2;
            }
            "positioned" => {
                clauses.push(format!(
                    "在坐标 ({}, {}, {})",
                    arg_cn(i + 1),
                    arg_cn(i + 2),
                    arg_cn(i + 3)
                ));
                i += 4;
            }
            "if" => {
                if args.get(i + 1).map(|s| s.as_str()) == Some("entity") {
                    clauses.push(format!("当 {} 存在时", arg_cn(i + 2)));
                    i += 3;
                } else {
                    clauses.push(format!(
                        "当 ({}, {}, {}) 处为【{}】时",
                        arg_cn(i + 2),
                        arg_cn(i + 3),
                        arg_cn(i + 4),
                        arg_cn(i + 5)
                    ));
                    i += 6;
                }
            }
            _ => i += 1,
        }
    }

    let inner_result = execute(inner.clone());
    let prefix = if clauses.is_empty() {
        String::new()
    } else {
        format!("{}，", clauses.join("，"))
    };
    ExecutionResult {
        success: inner_result.success,
        message: if inner_result.success {
            format!("已执行：{prefix}{}", inner_result.message)
        } else {
            inner_result.message
        },
    }
}

/// 执行指令（模拟），返回成功/失败与反馈消息
pub fn execute(input: String) -> ExecutionResult {
    let trimmed = input.trim();
    let body = trimmed.strip_prefix('/').unwrap_or(trimmed);
    if body.trim().is_empty() {
        return ExecutionResult { success: false, message: "指令为空".into() };
    }

    // 复用 analyze 的完整校验：光标置于最后一个 token 末尾 + 1，
    // 使全部 token 都被视为“已完成”，从而进行完整性与语法校验。
    let tokens = tokenize(body);
    let last_end = tokens.last().map(|t| t.end).unwrap_or(0);
    let analysis = analyze(body.to_string(), (last_end + 1) as i32);

    if let Some(err) = analysis.errors.first() {
        return ExecutionResult { success: false, message: err.message.clone() };
    }
    if !analysis.complete {
        return ExecutionResult {
            success: false,
            message: if analysis.usage.is_empty() {
                format!("未知指令：/{}", tokens[0].text)
            } else {
                format!("指令不完整，用法：{}", analysis.usage)
            },
        };
    }

    // 解析参数
    let cmd_name = tokens[0].text.clone();
    let cmd = commands().into_iter().find(|c| c.name == cmd_name || c.aliases.iter().any(|a| *a == cmd_name));
    let cmd = match cmd {
        Some(c) => c,
        None => return ExecutionResult { success: false, message: "未知指令".into() },
    };
    let args: Vec<String> = tokens[1..].iter().map(|t| t.text.clone()).collect();

    if let Err(e) = semantic_check(&cmd.name, &args) {
        return ExecutionResult { success: false, message: e };
    }

    if cmd.name == "execute" {
        return execute_execute(&args);
    }

    ExecutionResult { success: true, message: execute_message(&cmd.name, &args) }
}

/// 指令面板数据
pub fn list_commands() -> Vec<CommandInfo> {
    commands()
        .into_iter()
        .map(|c| CommandInfo {
            name: c.name.to_string(),
            aliases: c.aliases.iter().map(|s| s.to_string()).collect(),
            usage: build_usage(&c),
            description: c.desc.to_string(),
            op_only: c.op,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chars_at_end(s: &str) -> i32 {
        s.chars().count() as i32
    }

    #[test]
    fn suggest_command_names() {
        let r = analyze("/g".into(), 2);
        assert!(r.suggestions.iter().any(|s| s.label == "give"));
        assert!(r.suggestions.iter().any(|s| s.label == "gamemode"));
    }

    #[test]
    fn suggest_items_with_prefix() {
        let input = "/give @a diam";
        let r = analyze(input.into(), chars_at_end(input));
        assert!(r.suggestions.iter().any(|s| s.insert == "diamond"));
        assert!(r.errors.is_empty());
    }

    #[test]
    fn hint_at_cursor() {
        let input = "/give @a ";
        let r = analyze(input.into(), chars_at_end(input));
        assert!(!r.hint.is_empty());
        assert!(r.hint.contains("物品"));
    }

    #[test]
    fn syntax_error_has_position() {
        let r = analyze("/give @a diamnd".into(), chars_at_end("/give @a diamnd"));
        eprintln!("DEBUG syntax: {:?}", r.errors);
        assert!(!r.errors.is_empty());
        let e = &r.errors[0];
        assert!(e.start >= 0 && e.end > e.start);
        assert!(e.message.contains("物品") || e.message.contains("未知的物品"));
    }

    #[test]
    fn execute_success() {
        let r = execute("/give @a diamond 64".into());
        assert!(r.success, "message = {}", r.message);
        assert!(r.message.contains("64"));
    }

    #[test]
    fn execute_unknown_block_fails() {
        let r = execute("/setblock 1 2 3 not_a_block".into());
        assert!(!r.success);
    }

    #[test]
    fn execute_too_many_args_fails() {
        let r = execute("/gamemode creative everyone extra".into());
        assert!(!r.success);
    }

    #[test]
    fn execute_incomplete_fails() {
        let r = execute("/give @a".into());
        assert!(!r.success);
        assert!(r.message.contains("用法"));
    }

    #[test]
    fn execute_aliases_and_subcommands() {
        for cmd in [
            "/time set day",
            "/teleport 1 2 3",
            "/effect give @a speed 30 1 true",
            "/effect clear @a",
            "/effect give @a speed 30",
            "/tp ~ ~10 ~",
            "/gamemode creative @a",
            "/title @a title Hello World",
            "/say hi",
            "/me waves",
            "/kick @a cheating",
            "/tellraw @a {\"text\":\"hi\"}",
            "/say 你好 世界",
            "/xp add @a 10 levels",
            "/gamerule keepInventory true",
            "/weather thunder 60",
            "/seed",
            "/help",
        ] {
            let r = execute(cmd.into());
            assert!(r.success, "{cmd} failed: {}", r.message);
        }
    }

    #[test]
    fn complete_flag_true_for_full_command() {
        let r = analyze("/time set day".into(), chars_at_end("/time set day"));
        assert!(r.complete);
        assert!(r.errors.is_empty());
    }

    #[test]
    fn replace_start_points_at_partial_token() {
        let input = "/give @a dia";
        let r = analyze(input.into(), chars_at_end(input));
        eprintln!("DEBUG rs: {} (expect 9)", r.replace_start);
        assert_eq!(r.replace_start, 9); // "dia" 的起始位置（含 '/'）
    }

    #[test]
    fn list_commands_nonempty() {
        assert!(list_commands().len() > 20);
    }

    // ───────────── 新增指令测试 ─────────────

    #[test]
    fn execute_command_runs_inner() {
        let r = execute("/execute as @a run give @a diamond 1".into());
        assert!(r.success, "message = {}", r.message);
        assert!(
            r.message.contains("所有玩家") && r.message.contains("钻石"),
            "message = {}",
            r.message
        );
    }

    #[test]
    fn execute_command_invalid_inner_fails() {
        let r = execute("/execute as @a run give @a diamnd".into());
        assert!(!r.success, "message = {}", r.message);
    }

    #[test]
    fn execute_positioned_and_if() {
        for cmd in [
            "/execute positioned 1 2 3 run say hi",
            "/execute at @a run time set day",
            "/execute if entity @a run say ok",
            "/execute if block 1 2 3 stone run say ok",
            "/execute as @a at @s run summon zombie",
        ] {
            let r = execute(cmd.into());
            assert!(r.success, "{cmd} failed: {}", r.message);
        }
    }

    #[test]
    fn required_commands() {
        for cmd in [
            "/msg @a 你好 世界",
            "/tell @p see you",
            "/w @r psst",
            "/tag @a add vip",
            "/tag @a remove vip",
            "/tag @a list",
            "/locate structure village",
            "/locate biome cherry_grove",
            "/setworldspawn 0 70 0",
            "/setworldspawn",
            "/data get entity @a",
            "/data merge entity @a {Health:20f}",
            "/data get block 1 2 3",
            "/scoreboard objectives add kills totalKillCount",
            "/scoreboard objectives setdisplay sidebar kills",
            "/scoreboard players set @a kills 10",
            "/scoreboard players add @a coins 5",
        ] {
            let r = execute(cmd.into());
            assert!(r.success, "{cmd} failed: {}", r.message);
        }
    }

    #[test]
    fn recommended_commands() {
        for cmd in [
            "/bossbar add custom:hp {\"text\":\"血量\"}",
            "/bossbar set custom:hp value 10",
            "/bossbar set custom:hp color red",
            "/team add red",
            "/team join red @a",
            "/team modify red color red",
            "/playsound entity.player.levelup master @a",
            "/playsound block.note_block.pling master @a ~ ~ ~ 1 2",
            "/stopsound @a",
            "/stopsound @a master",
            "/item replace entity @a weapon.mainhand diamond_sword",
            "/item replace block 1 2 3 container.0 diamond 32",
            "/worldborder set 1000 5",
            "/worldborder center 0 0",
            "/worldborder get",
            "/attribute @a generic.max_health base set 40",
            "/attribute @a generic.movement_speed get",
        ] {
            let r = execute(cmd.into());
            assert!(r.success, "{cmd} failed: {}", r.message);
        }
    }

    #[test]
    fn server_admin_commands() {
        for cmd in [
            "/save-all",
            "/save-all flush",
            "/stop",
            "/pardon Steve",
            "/unban Steve",
            "/banlist",
            "/banlist players",
        ] {
            let r = execute(cmd.into());
            assert!(r.success, "{cmd} failed: {}", r.message);
        }
    }

    #[test]
    fn misc_commands() {
        for cmd in [
            "/clearspawnpoint",
            "/clearspawnpoint @a",
            "/damage @a 5",
            "/damage @a 10 fall",
            "/damage @a 0", // 语义错误
            "/ride @a mount zombie",
            "/ride @a dismount",
            "/spectate",
            "/spectate ender_dragon",
        ] {
            let r = execute(cmd.into());
            // "/damage @a 0" 应失败
            let should_fail = cmd.ends_with(" 0");
            assert_eq!(!r.success, should_fail, "{cmd}: {}", r.message);
        }
    }

    #[test]
    fn new_command_suggestions() {
        // execute 链式补全
        let r = analyze("/execute ".into(), 9);
        assert!(r.suggestions.iter().any(|s| s.insert == "as"));
        assert!(r.suggestions.iter().any(|s| s.insert == "if"));
        // locate 子指令
        let r2 = analyze("/locate str".into(), 11);
        assert!(r2.suggestions.iter().any(|s| s.insert == "structure"));
        // scoreboard 子指令
        let r3 = analyze("/scoreboard obj".into(), 15);
        assert!(r3.suggestions.iter().any(|s| s.insert == "objectives"));
        // 音效 ID 补全
        let r4 = analyze("/playsound entity.player.le".into(), 27);
        assert!(r4.suggestions.iter().any(|s| s.insert == "entity.player.levelup"));
    }

    #[test]
    fn execute_run_inner_live_analysis() {
        // 输入 execute run 后的子指令不产生外层语法错误
        let input = "/execute as @a run give @a diam";
        let r = analyze(input.into(), chars_at_end(input));
        assert!(r.errors.is_empty(), "errors = {:?}", r.errors);
        // 内层子指令的补全建议会透出（dia → diamond）
        assert!(r.suggestions.iter().any(|s| s.insert == "diamond"), "suggestions = {:?}", r.suggestions.iter().map(|s| s.label.clone()).collect::<Vec<_>>());
    }

    #[test]
    fn execute_clause_error_position() {
        let r = analyze("/execute bogus run say hi".into(), chars_at_end("/execute bogus run say hi"));
        assert!(!r.errors.is_empty(), "errors = {:?}", r.errors);
        assert!(r.errors[0].message.contains("子句"));
    }

    #[test]
    fn execute_clause_suggestions() {
        let r = analyze("/execute ".into(), 9);
        assert!(r.suggestions.iter().any(|s| s.insert == "as"));
        assert!(r.suggestions.iter().any(|s| s.insert == "positioned"));
    }

    // ───────────── 第二批指令测试 ─────────────

    #[test]
    fn world_and_feature_commands() {
        for cmd in [
            "/advancement grant @a only story/mine_diamond",
            "/advancement revoke @a everything",
            "/defaultgamemode creative",
            "/function my_pack:hello",
            "/loot give @a minecraft:chests/simple_dungeon",
            "/loot spawn 1 2 3 minecraft:chests/end_city_treasure",
            "/particle flame @a",
            "/particle end_rod 1 2 3 0.5 0.5 0.5 0.1 10",
            "/place feature village",
            "/place structure ancient_city 1 2 3",
            "/recipe give @a minecraft:iron_ingot",
            "/reload",
            "/schedule function my_pack:tick 20",
            "/spreadplayers 0 0 100 200 false @a",
            "/teammsg 撤退！",
            "/tm 集合！",
            "/tick query",
            "/tick rate 10",
            "/tick freeze",
            "/trigger my_trigger",
            "/version",
            "/forceload add 0 0",
            "/forceload remove all",
            "/fillbiome 0 0 100 100 plains",
            "/random value 1..10",
            "/return 5",
            "/rotate @a 90 0",
            "/waypoint list",
            "/stopwatch create run1",
            "/datapack list",
            "/dialog show @a welcome_screen",
            "/swing @a mainhand",
            "/fetchprofile @a",
            "/posteffect clear",
        ] {
            let r = execute(cmd.into());
            assert!(r.success, "{cmd} failed: {}", r.message);
        }
    }

    #[test]
    fn server_admin_commands_batch2() {
        for cmd in [
            "/whitelist add Steve",
            "/whitelist on",
            "/ban-ip 127.0.0.1",
            "/ban-ip 127.0.0.1 恶意扫描",
            "/pardon-ip 127.0.0.1",
            "/setidletimeout 30",
            "/save-off",
            "/save-on",
            "/publish",
            "/publish 25565",
            "/unpublish",
            "/transfer mc.example.com 25565",
            "/perf start",
            "/debug start",
            "/jfr stop",
            "/serverpack",
            "/debugconfig test_config",
            "/debugpath start",
            "/debugmobspawning set 20",
            "/warden_spawn_tracker reset",
            "/spawn_armor_trims",
            "/raid list @a",
            "/chase mycommand",
            "/test runall",
        ] {
            let r = execute(cmd.into());
            assert!(r.success, "{cmd} failed: {}", r.message);
        }
    }

    #[test]
    fn new_command_suggestions_batch2() {
        // 粒子 ID 补全
        let r = analyze("/particle fla".into(), 13);
        assert!(r.suggestions.iter().any(|s| s.insert == "flame"));
        // 进度 ID 补全
        let adv_input = "/advancement grant @a only story/mine_di";
        let r2 = analyze(adv_input.into(), chars_at_end(adv_input));
        assert!(r2.suggestions.iter().any(|s| s.insert == "story/mine_diamond"));
        // tick 子指令
        let r3 = analyze("/tick ".into(), 6);
        assert!(r3.suggestions.iter().any(|s| s.insert == "freeze"));
        // whitelist 子指令
        let r4 = analyze("/whitelist ".into(), 11);
        assert!(r4.suggestions.iter().any(|s| s.insert == "reload"));
    }

    #[test]
    fn command_count_matches_expectation() {
        // 覆盖 Vanilla Commands.java 的主要注册项
        assert!(list_commands().len() >= 90, "count = {}", list_commands().len());
    }

    // ───────────── 物品组件 / 旧式 NBT ─────────────

    fn assert_all_succeed(cmds: &[&str]) {
        for cmd in cmds {
            let r = execute(cmd.to_string());
            assert!(r.success, "{cmd} 失败：{}", r.message);
        }
    }

    #[test]
    fn give_with_components() {
        assert_all_succeed(&[
            "/give @a diamond_sword[minecraft:enchantments={levels:{\"minecraft:sharpness\":5}}]",
            "/give @a diamond_sword[minecraft:custom_name=\"Excalibur\"] 1",
            "/give @a diamond[minecraft:unbreakable={}] 64",
            "/give @a golden_apple[minecraft:food={nutrition:4,saturation:9.6}]",
            "/give @a white_wool 16",
            "/give @a netherite_pickaxe 1",
            "/give @a music_disc_pigstep",
            "/give @a cherry_planks[minecraft:custom_model_data=7]",
            "/give @a pig_spawn_egg 3",
        ]);
    }

    #[test]
    fn give_with_legacy_nbt() {
        assert_all_succeed(&[
            "/give @a diamond_sword{Enchantments:[{id:\"minecraft:sharpness\",lvl:5}]}",
            "/give @a stick{CustomModelData:1} 3",
            "/give @a stone{HideFlags:1}",
        ]);
    }

    #[test]
    fn give_component_with_spaces_inside() {
        // 组件里的空格不应把 token 拆成多个参数
        let r =
            execute("/give @a diamond_sword[minecraft:custom_name=\"Very Cool Sword\"]".into());
        assert!(r.success, "message = {}", r.message);
        assert!(r.message.contains("自定义名称"), "message = {}", r.message);
    }

    #[test]
    fn give_reports_component_summary() {
        let r = execute(
            "/give @a diamond_sword[minecraft:enchantments={levels:{}},minecraft:unbreakable={}]"
                .into(),
        );
        assert!(r.success, "message = {}", r.message);
        assert!(r.message.contains("附魔"), "message = {}", r.message);
        assert!(r.message.contains("无法破坏"), "message = {}", r.message);
    }

    #[test]
    fn give_with_broken_data_fails() {
        for cmd in [
            "/give @a diamond_sword[minecraft:damage=5",
            "/give @a diamond_sword{Enchantments:[}]",
            "/give @a not_an_item[minecraft:damage=1]",
        ] {
            let r = execute(cmd.to_string());
            assert!(!r.success, "{cmd} 本应失败，却通过了：{}", r.message);
        }
    }

    #[test]
    fn component_suggestions_after_bracket() {
        // 敲到命名空间之后，按组件名本身过滤
        let input = "/give @a diamond_sword[minecraft:ench";
        let r = analyze(input.into(), chars_at_end(input));
        assert!(
            r.suggestions
                .iter()
                .any(|s| s.insert.contains("minecraft:enchantments")),
            "suggestions = {:?}",
            r.suggestions
                .iter()
                .map(|s| s.insert.clone())
                .collect::<Vec<_>>()
        );

        // 逗号之后接着补下一个组件，并保留已经写完的部分
        let input2 = "/give @a diamond_sword[minecraft:damage=1,minecraft:unb";
        let r2 = analyze(input2.into(), chars_at_end(input2));
        assert!(
            r2.suggestions
                .iter()
                .any(|s| s.insert.contains(",minecraft:unbreakable")),
            "suggestions = {:?}",
            r2.suggestions
                .iter()
                .map(|s| s.insert.clone())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn legacy_nbt_key_suggestions() {
        let input = "/give @a diamond_sword{Ench";
        let r = analyze(input.into(), chars_at_end(input));
        assert!(
            r.suggestions
                .iter()
                .any(|s| s.insert.contains("Enchantments")),
            "suggestions = {:?}",
            r.suggestions
                .iter()
                .map(|s| s.insert.clone())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn item_registry_covers_common_ids() {
        for id in [
            "diamond_sword",
            "netherite_chestplate",
            "light_blue_wool",
            "oak_planks",
            "pig_spawn_egg",
            "cherry_door",
            "bamboo_mosaic",
            "music_disc_pigstep",
            "spyglass",
            "tuff_brick_wall",
        ] {
            let r = execute(format!("/give @a {id}"));
            assert!(r.success, "{id} 不在物品表里：{}", r.message);
        }
    }

    #[test]
    fn item_registry_is_generated() {
        // 染色 / 材质 / 刷怪蛋的展开应当产出足够多的条目
        assert!(reg::items().len() > 800, "items = {}", reg::items().len());
        assert!(reg::blocks().len() > 400, "blocks = {}", reg::blocks().len());
    }

    // ───────────── NBT 与附加数据 ─────────────

    #[test]
    fn summon_accepts_nbt() {
        assert_all_succeed(&[
            "/summon zombie ~ ~ ~ {IsBaby:1b}",
            "/summon armor_stand 10 64 -20 {ShowArms:1b,NoGravity:1b}",
            "/summon creeper 1 2 3 {powered:1b}",
            "/summon item ~ ~1 ~ {Item:{id:\"minecraft:diamond\",Count:1b}}",
        ]);
    }

    #[test]
    fn summon_reports_nbt_summary() {
        let r = execute("/summon zombie ~ ~ ~ {IsBaby:1b,NoGravity:1b}".into());
        assert!(r.success, "message = {}", r.message);
        assert!(r.message.contains("僵尸"), "message = {}", r.message);
        assert!(r.message.contains("幼年"), "message = {}", r.message);
    }

    #[test]
    fn blocks_accept_states_and_nbt() {
        assert_all_succeed(&[
            "/setblock 1 2 3 oak_stairs[facing=north,half=bottom]",
            "/setblock ~ ~ ~ chest{Items:[]}",
            "/fill 0 0 0 2 2 2 oak_slab[type=top] hollow",
            "/execute if block 1 2 3 oak_stairs[facing=north] run say ok",
            "/item replace entity @a weapon.mainhand diamond_sword[minecraft:unbreakable={}]",
            "/data merge entity @a {Health:20f}",
            "/data merge block 1 2 3 {Items:[]}",
        ]);
    }

    #[test]
    fn bad_nbt_is_rejected() {
        for cmd in [
            "/summon zombie ~ ~ ~ IsBaby:1b",
            "/summon zombie ~ ~ ~ {IsBaby:1b",
            "/setblock 1 2 3 oak_stairs[facing=north",
            "/data merge entity @a Health:20f",
        ] {
            let r = execute(cmd.to_string());
            assert!(!r.success, "{cmd} 本应失败，却通过了：{}", r.message);
        }
    }

    #[test]
    fn nbt_key_suggestions() {
        // summon 里输入 `{Is` 应当补出实体 NBT 键
        let input = "/summon zombie {Is";
        let r = analyze(input.into(), chars_at_end(input));
        assert!(
            r.suggestions
                .iter()
                .any(|s| s.insert.contains("IsBaby")),
            "suggestions = {:?}",
            r.suggestions
                .iter()
                .map(|s| s.insert.clone())
                .collect::<Vec<_>>()
        );

        // 还没写 `{` 时给出骨架
        let input2 = "/summon zombie ";
        let r2 = analyze(input2.into(), chars_at_end(input2));
        assert!(r2.suggestions.iter().any(|s| s.insert == "{"));

        // 方块参数写 `{` 时同样补 NBT 键
        let input3 = "/setblock 1 2 3 chest{It";
        let r3 = analyze(input3.into(), chars_at_end(input3));
        assert!(
            r3.suggestions.iter().any(|s| s.insert.contains("Items")),
            "suggestions = {:?}",
            r3.suggestions
                .iter()
                .map(|s| s.insert.clone())
                .collect::<Vec<_>>()
        );
    }

    // ───────────── damage 的 at / by / from ─────────────

    #[test]
    fn damage_supports_at_by_from() {
        assert_all_succeed(&[
            "/damage @a 5",
            "/damage @a 5 fall",
            "/damage @a 5 fall at 1 2 3",
            "/damage @a 5 fall at ~ ~1 ~",
            "/damage @a 5 fall by @p",
            "/damage @a 5 fall by @p from @s",
            "/damage @e[type=zombie] 3 arrow at 0 64 0",
        ]);
    }

    #[test]
    fn damage_reports_source() {
        let r = execute("/damage @a 5 fall at 1 2 3".into());
        assert!(r.success, "message = {}", r.message);
        assert!(r.message.contains("摔落"), "message = {}", r.message);
        assert!(r.message.contains("(1, 2, 3)"), "message = {}", r.message);

        let r2 = execute("/damage @a 5 fall by @p from @s".into());
        assert!(r2.success, "message = {}", r2.message);
        assert!(r2.message.contains("最近的玩家"), "message = {}", r2.message);
        assert!(r2.message.contains("指令执行者"), "message = {}", r2.message);
    }

    #[test]
    fn damage_suggests_at_and_by() {
        // 打完伤害类型后，应提示还能接 at / by
        let input = "/damage @a 5 fall ";
        let r = analyze(input.into(), chars_at_end(input));
        let labels: Vec<&str> = r.suggestions.iter().map(|s| s.insert.as_str()).collect();
        assert!(labels.contains(&"at"), "suggestions = {labels:?}");
        assert!(labels.contains(&"by"), "suggestions = {labels:?}");

        // `at` 之后是坐标
        let input2 = "/damage @a 5 fall at ";
        let r2 = analyze(input2.into(), chars_at_end(input2));
        assert!(
            r2.suggestions.iter().any(|s| s.insert == "~"),
            "suggestions = {:?}",
            r2.suggestions
                .iter()
                .map(|s| s.insert.clone())
                .collect::<Vec<_>>()
        );

        // `by` 之后是实体选择器
        let input3 = "/damage @a 5 fall by ";
        let r3 = analyze(input3.into(), chars_at_end(input3));
        assert!(
            r3.suggestions.iter().any(|s| s.insert.starts_with('@')),
            "suggestions = {:?}",
            r3.suggestions
                .iter()
                .map(|s| s.insert.clone())
                .collect::<Vec<_>>()
        );
    }

    // ───────────── 各指令补齐的分支 ─────────────

    #[test]
    fn previously_missing_branches_are_filled() {
        assert_all_succeed(&[
            // xp 的 set / query
            "/xp add @p 30",
            "/xp add @p 30 levels",
            "/xp set @p 100",
            "/xp set @p 5 levels",
            "/xp query @p 30",
            "/xp query @p 5 levels",
            // effect clear 指定单个效果
            "/effect clear @a",
            "/effect clear @a speed",
            // clone 的过滤模式
            "/clone 0 0 0 2 2 2 10 10 10",
            "/clone 0 0 0 2 2 2 10 10 10 masked",
            "/clone 0 0 0 2 2 2 10 10 10 replace force",
            "/clone 0 0 0 2 2 2 10 10 10 masked move",
            // spawnpoint 的朝向
            "/spawnpoint @a 0 64 0",
            "/spawnpoint @a 0 64 0 90",
            // playsound 的最小音量
            "/playsound entity.player.levelup master @a ~ ~ ~ 1 1 1",
        ]);
    }

    #[test]
    fn filled_branch_messages_are_descriptive() {
        let r = execute("/xp set @p 5 levels".into());
        assert!(r.success, "message = {}", r.message);
        assert!(r.message.contains("等级"), "message = {}", r.message);

        let r2 = execute("/effect clear @a speed".into());
        assert!(r2.success, "message = {}", r2.message);
        assert!(r2.message.contains("迅捷"), "message = {}", r2.message);

        let r3 = execute("/clone 0 0 0 2 2 2 10 10 10 masked force".into());
        assert!(r3.success, "message = {}", r3.message);
        assert!(r3.message.contains("过滤"), "message = {}", r3.message);
        assert!(r3.message.contains("方式"), "message = {}", r3.message);

        let r4 = execute("/spawnpoint @a 0 64 0 90".into());
        assert!(r4.success, "message = {}", r4.message);
        assert!(r4.message.contains("(0, 64, 0)"), "message = {}", r4.message);
        assert!(r4.message.contains("90"), "message = {}", r4.message);
    }

    // ───────────── 中文反馈 ─────────────

    #[test]
    fn execute_messages_are_localized() {
        for (cmd, expect) in [
            ("/give @a diamond_sword 64", "钻石剑"),
            ("/give @a light_blue_wool", "淡蓝色羊毛"),
            ("/give @a pig_spawn_egg", "猪刷怪蛋"),
            ("/summon zombie", "僵尸"),
            ("/setblock 1 2 3 stone", "石头"),
            ("/effect give @a speed 30", "迅捷"),
            ("/enchant @a sharpness 5", "锋利"),
            ("/gamemode creative @a", "创造模式"),
            ("/weather rain", "雨天"),
            ("/tp @p", "最近的玩家"),
            ("/kill @e", "所有实体"),
            ("/difficulty hard", "困难"),
            ("/time set day", "白天"),
            ("/damage @a 5 fall", "摔落"),
            ("/fill 0 0 0 3 3 3 white_wool", "白色羊毛"),
            ("/particle flame 1 2 3", "火焰"),
        ] {
            let r = execute(cmd.to_string());
            assert!(r.success, "{cmd} 执行失败：{}", r.message);
            assert!(
                r.message.contains(expect),
                "{cmd} 的输出「{}」里没有「{expect}」",
                r.message
            );
        }
    }

    #[test]
    fn raw_ids_do_not_leak_into_messages() {
        // 常见 ID 不该以原始英文形式出现在反馈里
        for cmd in [
            "/give @a diamond_pickaxe",
            "/give @a oak_planks 3",
            "/summon creeper",
            "/setblock 0 0 0 netherrack",
            "/effect give @a regeneration 10",
        ] {
            let r = execute(cmd.to_string());
            assert!(r.success, "{cmd} 执行失败：{}", r.message);
            for raw in [
                "diamond_pickaxe",
                "oak_planks",
                "creeper",
                "netherrack",
                "regeneration",
            ] {
                assert!(
                    !r.message.contains(raw),
                    "{cmd} 的输出里仍出现原始 ID「{raw}」：{}",
                    r.message
                );
            }
        }
    }

    #[test]
    fn common_commands_read_as_chinese() {
        for cmd in [
            "/give @a diamond_sword[minecraft:enchantments={levels:{}}] 64",
            "/give @p light_blue_wool 16",
            "/setblock 1 2 3 netherrack",
            "/summon zombie 10 64 -5",
            "/effect give @p regeneration 30 1",
            "/tp @e[type=zombie] 100 64 -200",
            "/tp @a @s",
            "/tp 1 2 3",
            "/fill 0 0 0 3 3 3 white_wool hollow",
            "/clone 0 0 0 2 2 2 10 10 10 replace force",
            "/playsound entity.player.levelup master @a",
            "/damage @e 5 fall",
            "/execute as @a at @s run give @s diamond 1",
            "/time set midnight",
            "/weather thunder",
            "/xp add @p 30 levels",
        ] {
            let r = execute(cmd.to_string());
            assert!(r.success, "{cmd} 执行失败：{}", r.message);
            // 输出里不该再出现原始的英文 ID 或选择器
            for raw in [
                "diamond_sword",
                "light_blue_wool",
                "netherrack",
                "zombie",
                "regeneration",
                "white_wool",
                "entity.player.levelup",
                "@a",
                "@s",
                "@e",
                "@p",
            ] {
                assert!(
                    !r.message.contains(raw),
                    "{cmd} 的输出里仍有英文「{raw}」：{}",
                    r.message
                );
            }
        }
    }

    #[test]
    fn suggestion_details_use_own_chinese_name() {
        fn detail_of(input: &str, insert: &str) -> String {
            let r = analyze(input.into(), chars_at_end(input));
            r.suggestions
                .iter()
                .find(|s| s.insert == insert)
                .unwrap_or_else(|| panic!("{input} 应当补全 {insert}"))
                .detail
                .clone()
        }

        // 附魔：每条显示自己的中文名，而不是整列重复同一句类型说明
        assert_eq!(detail_of("/enchant @a aqua", "aqua_affinity"), "水下速掘");
        assert_eq!(detail_of("/enchant @a sharp", "sharpness"), "锋利");
        // 物品 / 实体 / 效果
        assert_eq!(detail_of("/give @a diamond_sw", "diamond_sword"), "钻石剑");
        assert_eq!(detail_of("/summon zom", "zombie"), "僵尸");
        assert_eq!(
            detail_of("/effect give @a regen", "regeneration"),
            "生命恢复"
        );
        // 含 `.` 的整条匹配
        assert_eq!(
            detail_of("/attribute @a generic.max_h", "generic.max_health"),
            "最大生命值"
        );
        // 音效来源的 block 要说"方块音效"，而不是物品语境里的"块"
        assert_eq!(
            detail_of("/playsound entity.player.levelup ", "block"),
            "方块音效"
        );

        // 整列都该是各自的中文名，不该有任何一条落回通用说明
        let list = analyze("/enchant @a ".into(), chars_at_end("/enchant @a "));
        let fallback = describe(ArgType::Enchant);
        let still_generic: Vec<&String> = list
            .suggestions
            .iter()
            .filter(|s| s.detail == fallback)
            .map(|s| &s.label)
            .collect();
        assert!(
            still_generic.is_empty(),
            "这些候选仍是通用说明：{still_generic:?}"
        );
    }

    #[test]
    fn all_candidates_are_listed() {
        // 附魔一共有多少就该列出多少（原先被硬截断到 12 条）
        let r = analyze("/enchant @a ".into(), chars_at_end("/enchant @a "));
        assert_eq!(
            r.suggestions.len(),
            reg::ENCHANTS.len(),
            "附魔候选应当全部列出"
        );

        // 物品候选同样不该被限制
        let r2 = analyze("/give @a ".into(), chars_at_end("/give @a "));
        assert!(
            r2.suggestions.len() > 500,
            "物品候选应当全部列出，实际只有 {}",
            r2.suggestions.len()
        );
        assert!(
            r2.suggestions.iter().all(|s| !s.detail.is_empty()),
            "每条候选都该有自己的说明"
        );
    }

    #[test]
    fn substring_search_works() {
        // 中间字符也能搜到：`eep` → creeper / sheep
        let input = "/summon eep";
        let r = analyze(input.into(), chars_at_end(input));
        let labels: Vec<&str> = r.suggestions.iter().map(|s| s.insert.as_str()).collect();
        assert!(labels.contains(&"creeper"), "suggestions = {labels:?}");
        assert!(labels.contains(&"sheep"), "suggestions = {labels:?}");

        // camelCase 的键名大小写不敏感
        let input2 = "/summon zombie {baby";
        let r2 = analyze(input2.into(), chars_at_end(input2));
        assert!(
            r2.suggestions.iter().any(|s| s.insert.contains("IsBaby")),
            "suggestions = {:?}",
            r2.suggestions
                .iter()
                .map(|s| s.insert.clone())
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn prefix_beats_substring() {
        // 完全匹配 > 前缀 > 词首 > 子串
        let input = "/give @a glass";
        let r = analyze(input.into(), chars_at_end(input));
        let labels: Vec<&str> = r.suggestions.iter().map(|s| s.insert.as_str()).collect();

        assert_eq!(labels.first(), Some(&"glass"), "完全匹配应当最前");
        let pane = labels.iter().position(|l| *l == "glass_pane").unwrap();
        // `white_stained_glass` 里的 glass 落在词首（`_glass`），属于次优
        let stained = labels
            .iter()
            .position(|l| *l == "white_stained_glass")
            .unwrap();
        assert!(
            pane < stained,
            "前缀命中应排在词首命中之前：{labels:?}"
        );

        // 子串命中排在最后
        let input2 = "/give @a wool";
        let r2 = analyze(input2.into(), chars_at_end(input2));
        assert!(
            r2.suggestions
                .iter()
                .all(|s| s.insert.ends_with("_wool")),
            "只应出现含 wool 的候选"
        );
        assert_eq!(
            r2.suggestions.first().map(|s| s.insert.as_str()),
            Some("black_wool"),
            "同分时按字母序"
        );
    }

    #[test]
    fn scoreboard_subcommands_all_work() {
        assert_all_succeed(&[
            // ── objectives ──
            "/scoreboard objectives add kills dummy",
            "/scoreboard objectives add kills totalKillCount",
            "/scoreboard objectives add kills dummy 击杀数",
            "/scoreboard objectives add teamkills teamkill.red",
            "/scoreboard objectives list",
            "/scoreboard objectives remove kills",
            "/scoreboard objectives setdisplay sidebar kills",
            "/scoreboard objectives setdisplay sidebar",
            "/scoreboard objectives modify kills displayname 击杀数",
            "/scoreboard objectives modify kills rendertype hearts",
            "/scoreboard objectives modify kills numberformat styled",
            "/scoreboard objectives modify kills numberformat blank",
            "/scoreboard objectives modify kills numberformat fixed 文本",
            // ── players ──
            "/scoreboard players list",
            "/scoreboard players list @a",
            "/scoreboard players get @a kills",
            "/scoreboard players set @a kills 10",
            "/scoreboard players add @a kills 1",
            "/scoreboard players remove @a kills 1",
            "/scoreboard players reset @a kills",
            "/scoreboard players reset @a",
            "/scoreboard players enable @a triggerObj",
            "/scoreboard players operation @a kills += @s coins",
            "/scoreboard players operation @a kills >< @s coins",
            "/scoreboard players display name @a kills 击杀数",
            "/scoreboard players display numberformat @a kills styled",
            "/scoreboard players display numberformat @a kills blank",
        ]);
    }

    #[test]
    fn scoreboard_rejects_bad_input() {
        for cmd in [
            "/scoreboard objectives add kills",      // 缺判据
            "/scoreboard objectives add kills dumy", // 判据拼错
            "/scoreboard objectives bogus",          // 未知子指令
            "/scoreboard players set @a kills abc",  // 分数不是整数
        ] {
            let r = execute(cmd.to_string());
            assert!(!r.success, "{cmd} 本应失败，却通过了：{}", r.message);
        }
    }

    #[test]
    fn selectors_are_described() {
        assert_eq!(reg::localize("@a"), "所有玩家");
        assert_eq!(reg::localize("@p"), "最近的玩家");
        assert_eq!(reg::localize("@e[type=zombie]"), "所有实体[type=僵尸]");
        // 玩家名保持原样
        assert_eq!(reg::localize("Notch"), "Notch");
        // 认不出来的 ID 原样返回，不丢信息
        assert_eq!(reg::localize("some_unknown_thing"), "some_unknown_thing");
    }
}