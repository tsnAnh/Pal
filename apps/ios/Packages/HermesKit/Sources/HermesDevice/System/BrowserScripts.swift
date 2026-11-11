#if os(macOS)
import Foundation

enum BrowserFamily: String, Sendable, Equatable {
    case safari
    case chromium

    static let bundles: [String: (family: BrowserFamily, name: String)] = [
        "com.apple.Safari": (.safari, "Safari"),
        "com.apple.SafariTechnologyPreview": (.safari, "Safari Technology Preview"),
        "com.google.Chrome": (.chromium, "Google Chrome"),
        "com.google.Chrome.beta": (.chromium, "Google Chrome Beta"),
        "com.brave.Browser": (.chromium, "Brave Browser"),
        "com.microsoft.edgemac": (.chromium, "Microsoft Edge"),
        "com.vivaldi.Vivaldi": (.chromium, "Vivaldi"),
        "company.thebrowser.Browser": (.chromium, "Arc"),
        "org.chromium.Chromium": (.chromium, "Chromium"),
    ]

    var setupHint: String {
        switch self {
        case .safari: "In Safari, turn on Settings > Advanced > Show features for web developers, then Develop > Developer Settings > Allow JavaScript from Apple Events."
        case .chromium: "In your browser, choose View > Developer > Allow JavaScript from Apple Events."
        }
    }
}

struct BrowserTarget: Sendable, Equatable {
    var family: BrowserFamily
    var name: String
    var bundleID: String
}

enum BrowserScripts {
    static let textCharacterLimit = 200_000
    static let pollInterval: Duration = .milliseconds(400)

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private static let snapshot = """
    var visible=function(e){var r=e.getBoundingClientRect();var s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'};
    var snap=function(extra){var pw=Array.prototype.slice.call(document.querySelectorAll('input[type=password]')).some(visible);
    var body=document.body?document.body.innerText:'';
    var out={url:location.href,title:document.title,text:body.slice(0,\(textCharacterLimit)),login:pw,ready:document.readyState};
    for(var k in extra){out[k]=extra[k]}return JSON.stringify(out)};
    """

    static func wrap(_ body: String) -> String {
        "(function(){\(snapshot)\(body)})()"
    }

    static let read = wrap("return snap({});")

    static func contains(_ needle: String) -> String {
        wrap("return snap({matched:(document.body?document.body.innerText:'').toLowerCase().indexOf(\(jsString(needle.lowercased())))>=0});")
    }

    static func click(selector: String?, text: String?) -> String {
        let find: String
        if let selector {
            find = "var el=document.querySelector(\(jsString(selector)));"
        } else {
            find = """
            var want=\(jsString((text ?? "").lowercased()));
            var pool=document.querySelectorAll('a,button,[role=button],input[type=submit],input[type=button],summary,label');
            var el=null;
            for(var i=0;i<pool.length;i++){var c=pool[i];var t=((c.innerText||c.value||c.getAttribute('aria-label')||'')+'').trim().toLowerCase();
            if(t===want&&visible(c)){el=c;break}if(!el&&t.indexOf(want)>=0&&visible(c)){el=c}}
            """
        }
        return wrap(find + "if(!el){return JSON.stringify({error:'not_found'})}el.click();return snap({});")
    }

    static func type(selector: String, text: String, submit: Bool) -> String {
        wrap("""
        var el=document.querySelector(\(jsString(selector)));
        if(!el){return JSON.stringify({error:'not_found'})}
        var kind=((el.getAttribute('type')||'')+'').toLowerCase();
        var hint=[el.name,el.id,el.getAttribute('autocomplete'),el.getAttribute('aria-label'),el.placeholder].join(' ');
        if(kind==='password'||/password|passwd|passcode|one-time|\\botp\\b/i.test(hint)){return JSON.stringify({error:'password'})}
        var editable=el.tagName==='TEXTAREA'||el.tagName==='INPUT'||el.isContentEditable;
        if(!editable){return JSON.stringify({error:'not_editable'})}
        el.focus();
        if(el.isContentEditable){el.textContent=\(jsString(text))}else{
        var proto=el.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto,'value').set.call(el,\(jsString(text)))}
        el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));
        \(submit ? "if(el.form){if(el.form.requestSubmit){el.form.requestSubmit()}else{el.form.submit()}}" : "")
        return snap({});
        """)
    }

    static func runInWindow(_ target: BrowserTarget, windowID: Int, script: String) -> String {
        switch target.family {
        case .safari:
            "tell application id \(quoted(target.bundleID)) to do JavaScript \(quoted(script)) in current tab of window id \(windowID)"
        case .chromium:
            "tell application id \(quoted(target.bundleID)) to execute (active tab of window id \(windowID)) javascript \(quoted(script))"
        }
    }

    static func openWindow(_ target: BrowserTarget, url: String) -> String {
        switch target.family {
        case .safari:
            """
            tell application id \(quoted(target.bundleID))
            make new document with properties {URL:\(quoted(url))}
            return id of front window
            end tell
            """
        case .chromium:
            """
            tell application id \(quoted(target.bundleID))
            set w to make new window
            set URL of active tab of w to \(quoted(url))
            return id of w
            end tell
            """
        }
    }

    static func navigate(_ target: BrowserTarget, windowID: Int, url: String) -> String {
        switch target.family {
        case .safari:
            "tell application id \(quoted(target.bundleID)) to set URL of current tab of window id \(windowID) to \(quoted(url))"
        case .chromium:
            "tell application id \(quoted(target.bundleID)) to set URL of active tab of window id \(windowID) to \(quoted(url))"
        }
    }

    static func windowExists(_ target: BrowserTarget, windowID: Int) -> String {
        "tell application id \(quoted(target.bundleID)) to return (exists window id \(windowID))"
    }

    static func closeWindow(_ target: BrowserTarget, windowID: Int) -> String {
        "tell application id \(quoted(target.bundleID)) to close window id \(windowID)"
    }
}
#endif
