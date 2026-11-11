import Foundation

struct QuoteRule: Sendable {
    let open: [Unicode.Scalar]
    let close: [Unicode.Scalar]
    let multiline: Bool
    let escapes: Bool

    init(_ open: String, close: String? = nil, multiline: Bool = false, escapes: Bool = true) {
        self.open = Array(open.unicodeScalars)
        self.close = Array((close ?? open).unicodeScalars)
        self.multiline = multiline
        self.escapes = escapes
    }
}

struct LanguageSpec: Sendable {
    enum Style: Sendable {
        case code
        case markup
    }

    var style: Style = .code
    var keywords: Set<String> = []
    var caseInsensitiveKeywords = false
    var lineComments: [[Unicode.Scalar]] = []
    var blockComment: (open: [Unicode.Scalar], close: [Unicode.Scalar])?
    var quotes: [QuoteRule] = []
    var capitalizedTypes = false
    var functionCalls = true
    var attributePrefixes: Set<Unicode.Scalar> = []
    var shellVariables = false
    var hyphenIdentifiers = false
    var dollarIdentifiers = false
    var colorLiterals = false
    var keyTerminator: Unicode.Scalar?

    init(
        style: Style = .code,
        keywords: String = "",
        caseInsensitiveKeywords: Bool = false,
        lineComments: [String] = [],
        blockComment: (String, String)? = nil,
        quotes: [QuoteRule] = [],
        capitalizedTypes: Bool = false,
        functionCalls: Bool = true,
        attributePrefixes: String = "",
        shellVariables: Bool = false,
        hyphenIdentifiers: Bool = false,
        dollarIdentifiers: Bool = false,
        colorLiterals: Bool = false,
        keyTerminator: Unicode.Scalar? = nil
    ) {
        self.style = style
        let words = keywords.split(whereSeparator: \.isWhitespace).map(String.init)
        self.keywords = Set(caseInsensitiveKeywords ? words.map { $0.lowercased() } : words)
        self.caseInsensitiveKeywords = caseInsensitiveKeywords
        self.lineComments = lineComments.map { Array($0.unicodeScalars) }
        self.blockComment = blockComment.map { (open: Array($0.0.unicodeScalars), close: Array($0.1.unicodeScalars)) }
        self.quotes = quotes.sorted { $0.open.count > $1.open.count }
        self.capitalizedTypes = capitalizedTypes
        self.functionCalls = functionCalls
        self.attributePrefixes = Set(attributePrefixes.unicodeScalars)
        self.shellVariables = shellVariables
        self.hyphenIdentifiers = hyphenIdentifiers
        self.dollarIdentifiers = dollarIdentifiers
        self.colorLiterals = colorLiterals
        self.keyTerminator = keyTerminator
    }
}

enum CodeLanguageSpecs {
    static func resolve(_ language: String) -> LanguageSpec? {
        let name = language.lowercased()
        guard let canonical = aliases[name] else { return nil }
        return specs[canonical]
    }

    private static let doubleOrSingle = [QuoteRule("\""), QuoteRule("'")]
    private static let slashComments = ["//"]
    private static let cBlock = ("/*", "*/")

    private static let aliases: [String: String] = [
        "swift": "swift",
        "js": "javascript", "javascript": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "typescript": "typescript", "tsx": "typescript",
        "python": "python", "py": "python", "python3": "python",
        "go": "go", "golang": "go",
        "rust": "rust", "rs": "rust",
        "java": "java",
        "kotlin": "kotlin", "kt": "kotlin",
        "c": "c",
        "cpp": "cpp", "c++": "cpp", "cc": "cpp", "cxx": "cpp", "h": "cpp", "hpp": "cpp",
        "csharp": "csharp", "cs": "csharp", "c#": "csharp",
        "bash": "shell", "sh": "shell", "zsh": "shell", "shell": "shell",
        "json": "json", "jsonc": "jsonc",
        "yaml": "yaml", "yml": "yaml",
        "toml": "toml",
        "sql": "sql",
        "html": "markup", "xml": "markup", "svg": "markup",
        "css": "css", "scss": "scss",
        "ruby": "ruby", "rb": "ruby",
        "php": "php",
    ]

    static func knows(_ language: String) -> Bool {
        aliases[language.lowercased()] != nil
    }

    private static let specs: [String: LanguageSpec] = [
        "swift": LanguageSpec(
            keywords: """
            actor any as associatedtype async await break case catch class continue default defer deinit do else enum \
            extension fallthrough false fileprivate for func guard if import in indirect init inout internal is let nil \
            nonisolated open operator override precedencegroup private protocol public repeat rethrows return self Self \
            some static struct subscript super switch throw throws true try typealias var weak where while willSet didSet \
            get set lazy mutating final required convenience
            """,
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: [QuoteRule("\"\"\"", multiline: true), QuoteRule("\"")],
            capitalizedTypes: true,
            attributePrefixes: "@#"
        ),
        "javascript": jsFamily(types: false),
        "typescript": jsFamily(types: true),
        "python": LanguageSpec(
            keywords: """
            and as assert async await break class continue def del elif else except False finally for from global if \
            import in is lambda None nonlocal not or pass raise return True try while with yield match case self cls
            """,
            lineComments: ["#"],
            quotes: [QuoteRule("\"\"\"", multiline: true), QuoteRule("'''", multiline: true), QuoteRule("\""), QuoteRule("'")],
            capitalizedTypes: true,
            attributePrefixes: "@"
        ),
        "go": LanguageSpec(
            keywords: """
            break case chan const continue default defer else fallthrough for func go goto if import interface map \
            package range return select struct switch type var nil true false iota
            """,
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: [QuoteRule("`", multiline: true, escapes: false), QuoteRule("\""), QuoteRule("'")],
            capitalizedTypes: true
        ),
        "rust": LanguageSpec(
            keywords: """
            as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod \
            move mut pub ref return self Self static struct super trait true type unsafe use where while
            """,
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: [QuoteRule("\"", multiline: true)],
            capitalizedTypes: true
        ),
        "java": LanguageSpec(
            keywords: """
            abstract assert boolean break byte case catch char class const continue default do double else enum extends \
            final finally float for goto if implements import instanceof int interface long native new package private \
            protected public return short static strictfp super switch synchronized this throw throws transient try void \
            volatile while var record sealed permits yield true false null
            """,
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: [QuoteRule("\"\"\"", multiline: true), QuoteRule("\""), QuoteRule("'")],
            capitalizedTypes: true,
            attributePrefixes: "@"
        ),
        "kotlin": LanguageSpec(
            keywords: """
            as break by catch class companion constructor continue data do else enum false finally for fun if import in \
            init inline interface internal is lateinit null object open override package private protected public return \
            sealed super suspend this throw true try typealias val var when where while out reified
            """,
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: [QuoteRule("\"\"\"", multiline: true), QuoteRule("\""), QuoteRule("'")],
            capitalizedTypes: true,
            attributePrefixes: "@"
        ),
        "c": cFamily(keywords: """
        auto break case char const continue default do double else enum extern float for goto if inline int long register \
        restrict return short signed sizeof static struct switch typedef union unsigned void volatile while NULL true false
        """, types: false),
        "cpp": cFamily(keywords: """
        alignas alignof auto bool break case catch char class const constexpr continue decltype default delete do double \
        else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept \
        nullptr operator private protected public register return short signed sizeof static struct switch template this \
        throw true try typedef typename union unsigned using virtual void volatile while override final
        """, types: true),
        "csharp": LanguageSpec(
            keywords: """
            abstract as async await base bool break byte case catch char checked class const continue decimal default \
            delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in \
            int interface internal is lock long namespace new null object operator out override params private protected \
            public readonly ref return sbyte sealed short sizeof static string struct switch this throw true try typeof \
            uint ulong unchecked unsafe ushort using var virtual void volatile while record init get set
            """,
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: [QuoteRule("\"\"\"", multiline: true), QuoteRule("\""), QuoteRule("'")],
            capitalizedTypes: true,
            attributePrefixes: "#"
        ),
        "shell": LanguageSpec(
            keywords: """
            if then else elif fi for while until do done case esac in function select time return exit break continue \
            local export readonly declare unset source alias echo cd set shift trap eval exec true false
            """,
            lineComments: ["#"],
            quotes: [QuoteRule("\"", multiline: true), QuoteRule("'", multiline: true, escapes: false), QuoteRule("`", multiline: true)],
            functionCalls: false,
            shellVariables: true
        ),
        "json": LanguageSpec(
            keywords: "true false null",
            quotes: [QuoteRule("\"")],
            functionCalls: false,
            keyTerminator: ":"
        ),
        "jsonc": LanguageSpec(
            keywords: "true false null",
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: [QuoteRule("\"")],
            functionCalls: false,
            keyTerminator: ":"
        ),
        "yaml": LanguageSpec(
            keywords: "true false null yes no on off True False Null",
            lineComments: ["#"],
            quotes: doubleOrSingle,
            functionCalls: false,
            hyphenIdentifiers: true,
            keyTerminator: ":"
        ),
        "toml": LanguageSpec(
            keywords: "true false",
            lineComments: ["#"],
            quotes: [QuoteRule("\"\"\"", multiline: true), QuoteRule("'''", multiline: true), QuoteRule("\""), QuoteRule("'", escapes: false)],
            functionCalls: false,
            hyphenIdentifiers: true,
            keyTerminator: "="
        ),
        "sql": LanguageSpec(
            keywords: """
            add all alter and any as asc between by case check column constraint create cross database default delete \
            desc distinct drop else end exists foreign from full group having in index inner insert into is join key \
            left like limit not null offset on or order outer primary references right select set table then top union \
            unique update values view when where with begin commit rollback transaction true false returning
            """,
            caseInsensitiveKeywords: true,
            lineComments: ["--"],
            blockComment: cBlock,
            quotes: [QuoteRule("'"), QuoteRule("\""), QuoteRule("`")]
        ),
        "markup": LanguageSpec(style: .markup),
        "css": LanguageSpec(
            blockComment: cBlock,
            quotes: doubleOrSingle,
            attributePrefixes: "@",
            hyphenIdentifiers: true,
            colorLiterals: true
        ),
        "scss": LanguageSpec(
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: doubleOrSingle,
            attributePrefixes: "@$",
            hyphenIdentifiers: true,
            colorLiterals: true
        ),
        "ruby": LanguageSpec(
            keywords: """
            alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or \
            redo rescue retry return self super then true undef unless until when while yield require include extend \
            attr_accessor attr_reader attr_writer private public protected lambda proc
            """,
            lineComments: ["#"],
            quotes: [QuoteRule("\"", multiline: true), QuoteRule("'", multiline: true)],
            capitalizedTypes: true,
            attributePrefixes: "@"
        ),
        "php": LanguageSpec(
            keywords: """
            abstract and array as break callable case catch class clone const continue declare default do echo else \
            elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach \
            function global goto if implements include include_once instanceof insteadof interface isset list match \
            namespace new null or print private protected public readonly require require_once return static switch \
            throw trait true false try unset use var while yield
            """,
            lineComments: ["//", "#"],
            blockComment: cBlock,
            quotes: [QuoteRule("\"", multiline: true), QuoteRule("'", multiline: true)],
            capitalizedTypes: true,
            shellVariables: true
        ),
    ]

    private static func jsFamily(types: Bool) -> LanguageSpec {
        let base = """
        async await break case catch class const continue debugger default delete do else export extends false finally \
        for from function if import in instanceof let new null of return static super switch this throw true try typeof \
        undefined var void while with yield get set
        """
        let typed = """
         abstract as declare enum implements interface is keyof namespace private protected public readonly type \
        unknown never any satisfies
        """
        return LanguageSpec(
            keywords: types ? base + typed : base,
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: [QuoteRule("`", multiline: true), QuoteRule("\""), QuoteRule("'")],
            capitalizedTypes: true,
            attributePrefixes: types ? "@" : "",
            dollarIdentifiers: true
        )
    }

    private static func cFamily(keywords: String, types: Bool) -> LanguageSpec {
        LanguageSpec(
            keywords: keywords,
            lineComments: slashComments,
            blockComment: cBlock,
            quotes: doubleOrSingle,
            capitalizedTypes: types,
            attributePrefixes: "#"
        )
    }
}
