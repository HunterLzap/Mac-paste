namespace WinPaste.Core.OCR;

/// <summary>
/// 英文拼写校验器：Windows 下可注入系统 ISpellChecker (COM)，跨平台/测试环境提供内建高频词库与词形还原兜底
/// </summary>
public sealed class EnglishSpellChecker : IEnglishSpellChecker
{
    private readonly Func<string, bool>? _platformValidator;
    private readonly HashSet<string> _extraWords;

    public static EnglishSpellChecker Shared { get; } = new();

    public EnglishSpellChecker(Func<string, bool>? platformValidator = null, IEnumerable<string>? extraWords = null)
    {
        _platformValidator = platformValidator;
        _extraWords = extraWords is not null
            ? new HashSet<string>(extraWords, StringComparer.OrdinalIgnoreCase)
            : new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        TryLoadSystemWordList(_extraWords);
    }

    public bool IsValidEnglishWord(string word)
    {
        if (string.IsNullOrWhiteSpace(word) || word.Length < 2)
            return false;

        if (_platformValidator is not null)
        {
            try
            {
                if (_platformValidator(word))
                    return true;
            }
            catch
            {
                // Fall through to built-in lexicon.
            }
        }

        if (_extraWords.Contains(word) || BuiltInWords.Contains(word))
            return true;

        var lower = word.ToLowerInvariant();
        if (lower.Length > 3 && lower.EndsWith("s") && (BuiltInWords.Contains(lower[..^1]) || _extraWords.Contains(lower[..^1])))
            return true;
        if (lower.Length > 4 && lower.EndsWith("es") && (BuiltInWords.Contains(lower[..^2]) || _extraWords.Contains(lower[..^2])))
            return true;
        if (lower.Length > 4 && lower.EndsWith("ed") && (BuiltInWords.Contains(lower[..^2]) || _extraWords.Contains(lower[..^2]) || BuiltInWords.Contains(lower[..^1])))
            return true;
        if (lower.Length > 5 && lower.EndsWith("ing") && (BuiltInWords.Contains(lower[..^3]) || _extraWords.Contains(lower[..^3]) || BuiltInWords.Contains(lower[..^3] + "e")))
            return true;

        return false;
    }

    private static void TryLoadSystemWordList(HashSet<string> target)
    {
        // On macOS / Linux CI, /usr/share/dict/words is often available for realistic tests.
        const string unixDict = "/usr/share/dict/words";
        try
        {
            if (File.Exists(unixDict))
            {
                foreach (var line in File.ReadLines(unixDict))
                {
                    var w = line.Trim();
                    if (w.Length >= 2)
                        target.Add(w);
                }
            }
        }
        catch
        {
            // Optional fallback only.
        }
    }

    private static readonly HashSet<string> BuiltInWords = new(StringComparer.OrdinalIgnoreCase)
    {
        "about", "above", "access", "account", "across", "action", "active", "actual", "actually", "after",
        "again", "against", "agent", "agents", "agree", "ahead", "allow", "almost", "alone", "along",
        "already", "also", "although", "always", "among", "amount", "analysis", "another", "answer", "any",
        "anyone", "anything", "anywhere", "appear", "apply", "approach", "appropriate", "area", "around",
        "article", "assistant", "attention", "audio", "auto", "automatic", "automatically", "available",
        "average", "avoid", "back", "background", "balance", "based", "basic", "because", "become", "before",
        "begin", "behind", "being", "below", "benefit", "best", "better", "between", "beyond", "billion",
        "block", "board", "body", "book", "both", "bottom", "break", "bring", "browser", "build", "building",
        "built", "business", "button", "call", "camera", "cancel", "cannot", "capture", "card", "care",
        "carry", "case", "cause", "center", "central", "certain", "certainly", "change", "channel", "chapter",
        "character", "charge", "check", "choose", "circle", "city", "claim", "class", "clean", "clear",
        "clearly", "click", "client", "close", "cloud", "code", "collection", "color", "column", "combine",
        "come", "command", "comment", "common", "community", "company", "compare", "complete", "completely",
        "complex", "component", "computer", "concept", "condition", "conference", "config", "configure",
        "confirm", "connect", "connection", "consider", "consistent", "contact", "contain", "content",
        "context", "continue", "control", "convert", "copy", "core", "corner", "correct", "cost", "could",
        "count", "country", "course", "cover", "create", "credit", "cross", "current", "currently", "cursor",
        "custom", "customer", "daily", "dark", "data", "database", "date", "deal", "debug", "decide",
        "decision", "default", "define", "degree", "delete", "deliver", "delivery", "demand", "department",
        "depend", "describe", "description", "design", "desktop", "detail", "detect", "determine", "develop",
        "developer", "development", "device", "difference", "different", "difficult", "digital", "direct",
        "direction", "directly", "directory", "disable", "discover", "discuss", "display", "distance",
        "document", "does", "done", "double", "down", "download", "draft", "drag", "draw", "drive", "driven",
        "drop", "during", "each", "early", "earth", "easy", "easily", "edge", "edit", "editor", "effect",
        "effective", "effectively", "effort", "either", "element", "else", "email", "enable", "enabled",
        "end", "energy", "engine", "engineer", "engineering", "english", "enjoy", "enough", "ensure",
        "enter", "entire", "entry", "environment", "equal", "error", "escape", "especially", "essential",
        "even", "evening", "event", "ever", "every", "everyone", "everything", "everywhere", "exact",
        "exactly", "example", "excellent", "except", "exchange", "execute", "exist", "existing", "expand",
        "expect", "experience", "expert", "experts", "explain", "export", "express", "extend", "external",
        "extra", "extract", "face", "fact", "factor", "fail", "failed", "failure", "fair", "fall", "false",
        "family", "fast", "feature", "features", "feedback", "feel", "field", "figure", "file", "files",
        "fill", "filter", "final", "finally", "find", "fine", "finish", "first", "fixed", "flash", "flex",
        "flexible", "float", "floor", "flow", "focus", "folder", "follow", "following", "font", "food",
        "force", "form", "format", "former", "forward", "found", "frame", "framework", "free", "friendly",
        "from", "front", "full", "fully", "function", "future", "gain", "game", "general", "generally",
        "generate", "generation", "getting", "give", "given", "global", "goal", "going", "good", "government",
        "gradient", "great", "green", "grid", "ground", "group", "grow", "growth", "guarantee", "guard",
        "guess", "guide", "handle", "happen", "happy", "hard", "hardware", "have", "head", "header",
        "health", "hear", "heart", "heat", "heavy", "height", "hello", "help", "helpful", "here", "herself",
        "hidden", "hide", "high", "higher", "highlight", "highly", "himself", "history", "hold", "home",
        "hope", "horizontal", "host", "hotel", "hour", "hours", "house", "however", "huge", "human",
        "hundred", "icon", "idea", "identify", "ignore", "image", "images", "imagine", "immediate",
        "immediately", "impact", "implement", "implementation", "important", "improve", "include",
        "including", "income", "increase", "indeed", "index", "indicate", "individual", "industry", "info",
        "information", "initial", "inline", "input", "insert", "inside", "inspect", "install", "instance",
        "instead", "institution", "instruction", "integrate", "intelligence", "intelligent", "intend",
        "interact", "interaction", "interactive", "interest", "interesting", "interface", "internal",
        "international", "internet", "interpret", "interval", "into", "introduce", "invalid", "invite",
        "involve", "island", "issue", "issues", "item", "items", "itself", "join", "journey", "judge",
        "jump", "just", "keep", "keyboard", "kind", "king", "know", "knowledge", "known", "label", "labor",
        "lack", "land", "language", "languages", "large", "largely", "last", "late", "later", "latest",
        "launch", "layer", "layout", "lead", "leader", "learn", "learning", "least", "leave", "left",
        "legal", "length", "less", "lesson", "letter", "level", "library", "license", "life", "light",
        "like", "likely", "limit", "line", "linear", "lines", "link", "list", "listen", "little", "live",
        "load", "loading", "local", "locate", "location", "lock", "logic", "login", "long", "longer",
        "look", "loop", "lose", "loss", "lost", "love", "lower", "machine", "made", "main", "maintain",
        "major", "make", "manage", "management", "manager", "manual", "many", "margin", "mark", "market",
        "marketing", "match", "material", "matter", "maximum", "maybe", "mean", "meaning", "measure",
        "media", "medical", "medium", "meet", "meeting", "member", "memory", "mention", "menu", "merge",
        "message", "messages", "method", "middle", "might", "million", "mind", "minimal", "minimum",
        "minute", "minutes", "mirror", "miss", "missing", "mobile", "mode", "model", "models", "modern",
        "modify", "module", "moment", "money", "monitor", "month", "months", "more", "morning", "most",
        "mostly", "motion", "mouse", "move", "movement", "movie", "much", "multi", "multiple", "music",
        "must", "myself", "name", "named", "native", "natural", "nature", "near", "nearly", "necessary",
        "need", "needed", "needs", "negative", "neither", "network", "never", "news", "next", "nice",
        "night", "nine", "nobody", "node", "none", "normal", "north", "note", "notes", "nothing", "notice",
        "number", "numbers", "object", "observe", "obtain", "obvious", "obviously", "occur", "offer",
        "office", "official", "offline", "often", "once", "online", "only", "onto", "open", "operate",
        "operation", "opinion", "opportunity", "option", "options", "orange", "order", "ordinary",
        "organization", "organize", "original", "other", "others", "otherwise", "ought", "ourselves",
        "outer", "output", "outside", "over", "overall", "overlay", "overview", "owner", "package", "page",
        "pages", "pair", "panel", "paper", "paragraph", "parallel", "parent", "part", "partial",
        "particular", "particularly", "partner", "party", "pass", "password", "paste", "path", "pattern",
        "pause", "payment", "peace", "people", "percent", "perfect", "perform", "performance", "perhaps",
        "period", "permission", "person", "personal", "phase", "phone", "photo", "phrase", "physical",
        "pick", "picture", "piece", "pixel", "pixels", "place", "plain", "plan", "plane", "planet",
        "platform", "play", "player", "please", "plus", "point", "points", "policy", "popular",
        "population", "position", "positive", "possible", "possibly", "post", "potential", "power",
        "powered", "practical", "practice", "prefer", "prepare", "present", "preserve", "press", "pressure",
        "pretty", "prevent", "preview", "previous", "previously", "price", "primary", "print", "prior",
        "priority", "privacy", "private", "probably", "problem", "problems", "process", "processing",
        "produce", "product", "production", "professional", "profile", "program", "progress", "project",
        "promise", "prompt", "proper", "properly", "property", "protect", "provide", "provider", "public",
        "publish", "pull", "pure", "purple", "purpose", "push", "python", "quality", "quarter", "query",
        "question", "quick", "quickly", "quiet", "quite", "quote", "radius", "raise", "random", "range",
        "rapid", "rare", "rate", "rather", "ratio", "reach", "react", "read", "reader", "ready", "real",
        "reality", "realize", "really", "reason", "receive", "recent", "recently", "recognize",
        "recognition", "recommend", "record", "recover", "reduce", "refer", "reference", "reflect",
        "refresh", "region", "register", "regular", "relate", "related", "relation", "relative", "release",
        "relevant", "reliable", "remain", "remember", "remote", "remove", "render", "repeat", "replace",
        "reply", "report", "represent", "request", "require", "research", "reset", "resize", "resolve",
        "resource", "respect", "respond", "response", "responsibility", "rest", "restore", "result",
        "results", "resume", "retail", "retain", "return", "reveal", "review", "rich", "right", "ring",
        "rise", "risk", "road", "rock", "role", "roll", "room", "root", "rotate", "rough", "round", "route",
        "rule", "rules", "running", "safe", "safety", "same", "sample", "save", "scale", "scan", "scene",
        "schedule", "schema", "school", "science", "scope", "score", "screen", "screenshot", "script",
        "scroll", "search", "season", "second", "secondary", "secret", "section", "secure", "security",
        "seek", "seem", "segment", "select", "selected", "selection", "self", "sell", "send", "senior",
        "sense", "sentence", "separate", "sequence", "sequential", "series", "serious", "serve", "server",
        "service", "services", "session", "setting", "settings", "seven", "several", "shadow", "shape",
        "share", "shared", "sharp", "sheet", "shift", "shine", "ship", "short", "shortcut", "should",
        "shoulder", "show", "shown", "side", "sign", "signal", "signature", "significant", "silent",
        "silver", "similar", "simple", "simply", "since", "single", "site", "situation", "size", "skill",
        "skills", "skin", "sleep", "slice", "slide", "slight", "slightly", "slow", "slowly", "small",
        "smart", "smile", "smooth", "snap", "social", "software", "solid", "solution", "solve", "some",
        "somebody", "someone", "something", "sometimes", "somewhat", "somewhere", "soon", "sorry", "sort",
        "sound", "source", "south", "space", "span", "speak", "special", "specific", "specifically",
        "speech", "speed", "spell", "spend", "split", "spot", "spread", "spring", "square", "stable",
        "stack", "staff", "stage", "stand", "standard", "star", "start", "state", "statement", "static",
        "station", "status", "stay", "steady", "step", "steps", "stick", "still", "stock", "stop",
        "storage", "store", "story", "straight", "strange", "strategy", "stream", "street", "strength",
        "stress", "stretch", "strict", "strike", "string", "strip", "stroke", "strong", "structure",
        "student", "study", "stuff", "style", "subject", "submit", "subset", "success", "successful",
        "successfully", "such", "sudden", "suddenly", "suggest", "suit", "summary", "summer", "super",
        "supply", "support", "suppose", "sure", "surface", "surprise", "survey", "switch", "symbol",
        "sync", "system", "systems", "table", "take", "taken", "talk", "target", "task", "tasks", "team",
        "tech", "technical", "technology", "tell", "template", "ten", "tend", "term", "terms", "test",
        "testing", "text", "than", "thank", "that", "their", "them", "theme", "themselves", "then", "theory",
        "there", "therefore", "these", "they", "thick", "thin", "thing", "things", "think", "third",
        "this", "those", "though", "thought", "thousand", "thread", "three", "through", "throughout",
        "throw", "thus", "ticket", "tight", "time", "timeout", "timer", "times", "tiny", "title", "today",
        "together", "toggle", "token", "tomorrow", "tone", "tool", "toolbar", "tools", "topic", "total",
        "totally", "touch", "toward", "towards", "town", "track", "trade", "traffic", "train", "training",
        "transfer", "transform", "transition", "translate", "translated", "translation", "transparent",
        "travel", "treat", "tree", "trend", "trial", "triangle", "trigger", "trim", "trip", "true", "truly",
        "trust", "truth", "turn", "twice", "type", "typical", "typically", "unable", "under", "understand",
        "undo", "uniform", "union", "unique", "unit", "united", "universal", "unless", "unlike", "until",
        "update", "upgrade", "upload", "upon", "upper", "urban", "usage", "used", "useful", "user",
        "users", "using", "usual", "usually", "utility", "valid", "validate", "value", "values", "variable",
        "variant", "various", "vector", "verify", "version", "vertical", "very", "video", "view", "views",
        "virtual", "visible", "vision", "visit", "visual", "voice", "volume", "wait", "waiting", "walk",
        "wall", "want", "warm", "warn", "warning", "watch", "water", "wave", "ways", "weak", "wealth",
        "wear", "weather", "website", "week", "weight", "welcome", "well", "west", "western", "what",
        "whatever", "wheel", "when", "whenever", "where", "whereas", "wherever", "whether", "which",
        "while", "white", "whole", "whom", "whose", "wide", "widely", "width", "wife", "wild", "will",
        "willing", "window", "windows", "wing", "winner", "winter", "wire", "wise", "wish", "with",
        "within", "without", "woman", "women", "wonder", "word", "words", "work", "worker", "working",
        "world", "worry", "worth", "would", "wrap", "write", "writer", "writing", "written", "wrong",
        "wrote", "year", "years", "yellow", "yesterday", "yield", "young", "your", "yours", "yourself",
        "zero", "zone"
    };
}
