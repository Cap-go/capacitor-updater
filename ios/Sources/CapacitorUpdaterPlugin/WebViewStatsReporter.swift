import Capacitor
import Foundation
import WebKit

final class WebViewStatsReporter {
    static let script = """
    (function(){
      if(window.__capgoWebViewErrorReporterInstalled){return;}
      window.__capgoWebViewErrorReporterInstalled=true;
      var maxReports=20,sentReports=0,queue=[],seen={};
      var sessionKey='CapacitorUpdater.webViewSession';
      var sessionId=String(Date.now())+'-'+Math.random().toString(36).slice(2);
      function s(value){
        try{
          if(value===undefined){return '';}
          if(value===null){return 'null';}
          if(typeof value==='string'){return value;}
          if(value&&typeof value.message==='string'){return value.message;}
          return String(value);
        }catch(_){return '';}
      }
      function stack(value){
        try{return value&&value.stack?String(value.stack):'';}catch(_){return '';}
      }
      function updater(){
        var cap=window.Capacitor;
        if(!cap||!cap.Plugins){return null;}
        return cap.Plugins.CapacitorUpdater||null;
      }
      function flush(){
        var plugin=updater();
        if(!plugin||typeof plugin.reportWebViewError!=='function'){return false;}
        while(queue.length){
          var payload=queue.shift();
          try{
            var result=plugin.reportWebViewError(payload);
            if(result&&typeof result.catch==='function'){result.catch(function(){});}
          }catch(_){}
        }
        return true;
      }
      var retries=0;
      function scheduleFlush(){
        if(flush()){return;}
        if(retries++<40){setTimeout(scheduleFlush,250);}
      }
      function send(payload){
        try{
          if(sentReports>=maxReports){return;}
          payload.href=payload.href||location.href||'';
          payload.user_agent=navigator.userAgent||'';
          payload.session_id=sessionId;
          var key=[payload.type,payload.message,payload.source,payload.line,payload.column,payload.tag_name].join('|');
          if(seen[key]){return;}
          seen[key]=true;
          sentReports+=1;
          queue.push(payload);
          scheduleFlush();
        }catch(_){}
      }
      function readSession(){
        try{return JSON.parse(localStorage.getItem(sessionKey)||'null')||null;}catch(_){return null;}
      }
      function writeSession(active){
        try{
          localStorage.setItem(sessionKey,JSON.stringify({
            id:sessionId,
            active:active,
            href:location.href||'',
            started_at:window.__capgoWebViewSessionStartedAt,
            updated_at:String(Date.now())
          }));
        }catch(_){}
      }
      window.__capgoWebViewSessionStartedAt=String(Date.now());
      var previous=readSession();
      if(previous&&previous.active){
        send({
          type:'webview_unclean_restart',
          message:'WebView restarted without a clean page unload',
          previous_session_id:s(previous.id),
          previous_href:s(previous.href),
          previous_started_at:s(previous.started_at),
          previous_updated_at:s(previous.updated_at)
        });
      }
      writeSession(true);
      setInterval(function(){writeSession(true);},15000);
      function markClean(){writeSession(false);}
      window.addEventListener('pagehide',markClean,true);
      window.addEventListener('beforeunload',markClean,true);
      window.addEventListener('error',function(event){
        var target=event&&event.target;
        if(target&&target!==window&&(target.src||target.href)){
          send({
            type:'resource_error',
            message:'Resource failed to load',
            source:s(target.src||target.href),
            tag_name:s(target.tagName)
          });
          return;
        }
        send({
          type:'javascript_error',
          message:s((event&&event.message)||(event&&event.error)),
          source:s(event&&event.filename),
          line:s(event&&event.lineno),
          column:s(event&&event.colno),
          stack:stack(event&&event.error)
        });
      },true);
      window.addEventListener('unhandledrejection',function(event){
        var reason=event&&event.reason;
        send({type:'unhandled_rejection',message:s(reason),stack:stack(reason)});
      },true);
      document.addEventListener('securitypolicyviolation',function(event){
        send({
          type:'security_policy_violation',
          message:s(event&&event.violatedDirective),
          source:s(event&&event.blockedURI)
        });
      },true);
      document.addEventListener('deviceready',scheduleFlush,false);
      setTimeout(scheduleFlush,0);
    })();
    """

    private let implementation: CapgoUpdater
    private var installed = false

    init(implementation: CapgoUpdater) {
        self.implementation = implementation
    }

    func install(on webView: WKWebView?) {
        guard !installed else {
            return
        }
        guard let webView else {
            return
        }

        installed = true
        let userScript = WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(userScript)
        webView.evaluateJavaScript(Self.script, completionHandler: nil)
    }

    func reportError(_ call: CAPPluginCall) {
        let errorType = call.getString("type") ?? "javascript_error"
        let current = implementation.getCurrentBundle()
        implementation.sendStats(
            action: Self.statsAction(for: errorType),
            versionName: current.getVersionName(),
            oldVersionName: "",
            metadata: Self.buildMetadata([
                "type": errorType,
                "message": call.getString("message"),
                "source": call.getString("source"),
                "line": call.getString("line") ?? call.getString("lineno"),
                "column": call.getString("column") ?? call.getString("colno"),
                "stack": call.getString("stack"),
                "tag_name": call.getString("tag_name"),
                "href": call.getString("href"),
                "user_agent": call.getString("user_agent"),
                "session_id": call.getString("session_id"),
                "previous_session_id": call.getString("previous_session_id"),
                "previous_href": call.getString("previous_href"),
                "previous_started_at": call.getString("previous_started_at"),
                "previous_updated_at": call.getString("previous_updated_at")
            ])
        )
        call.resolve()
    }

    static func statsAction(for type: String) -> String {
        switch type {
        case "unhandled_rejection":
            return "webview_unhandled_rejection"
        case "resource_error":
            return "webview_resource_error"
        case "security_policy_violation":
            return "webview_security_policy_violation"
        case "webview_unclean_restart":
            return "webview_unclean_restart"
        case "render_process_gone":
            return "webview_render_process_gone"
        case "web_content_process_terminated":
            return "webview_content_process_terminated"
        case "javascript_error":
            return "webview_javascript_error"
        default:
            return "webview_javascript_error"
        }
    }

    static func buildMetadata(_ values: [String: String?]) -> [String: String] {
        var metadata: [String: String] = [:]
        put(&metadata, key: "error_type", value: payloadValue(values, "type") ?? "javascript_error", maxLength: 64)
        put(&metadata, key: "message", value: payloadValue(values, "message"), maxLength: 1_024)
        put(&metadata, key: "source", value: payloadValue(values, "source"), maxLength: 512)
        put(&metadata, key: "line", value: payloadValue(values, "line"), maxLength: 32)
        put(&metadata, key: "column", value: payloadValue(values, "column"), maxLength: 32)
        put(&metadata, key: "stack", value: payloadValue(values, "stack"), maxLength: 2_048)
        put(&metadata, key: "tag_name", value: payloadValue(values, "tag_name"), maxLength: 64)
        put(&metadata, key: "href", value: payloadValue(values, "href"), maxLength: 512)
        put(&metadata, key: "user_agent", value: payloadValue(values, "user_agent"), maxLength: 256)
        put(&metadata, key: "session_id", value: payloadValue(values, "session_id"), maxLength: 128)
        put(&metadata, key: "previous_session_id", value: payloadValue(values, "previous_session_id"), maxLength: 128)
        put(&metadata, key: "previous_href", value: payloadValue(values, "previous_href"), maxLength: 512)
        put(&metadata, key: "previous_started_at", value: payloadValue(values, "previous_started_at"), maxLength: 64)
        put(&metadata, key: "previous_updated_at", value: payloadValue(values, "previous_updated_at"), maxLength: 64)
        return metadata
    }

    private static func payloadValue(_ values: [String: String?], _ key: String) -> String? {
        guard let value = values[key] else {
            return nil
        }
        return value
    }

    private static func put(_ metadata: inout [String: String], key: String, value: String?, maxLength: Int) {
        guard let value = value, !value.isEmpty else {
            return
        }
        metadata[key] = String(value.prefix(maxLength))
    }
}
