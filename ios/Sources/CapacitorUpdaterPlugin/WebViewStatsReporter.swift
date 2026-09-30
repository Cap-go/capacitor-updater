import Foundation
import WebKit

/// JavaScript side of WebView health stats: errors, CSP violations, load timings
/// and unclean restarts, reported to the plugin as `reportWebViewError` calls.
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
      function pageDuration(){
        var started=Number(window.__capgoWebViewSessionStartedAt||Date.now());
        return String(Math.max(0,Date.now()-started));
      }
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
      document.addEventListener('DOMContentLoaded',function(){
        send({
          type:'webview_dom_content_loaded',
          message:'WebView DOM content loaded',
          duration_ms:pageDuration(),
          page_started_at:String(window.__capgoWebViewSessionStartedAt)
        });
      },true);
      window.addEventListener('load',function(){
        send({
          type:'webview_page_loaded',
          message:'WebView page loaded',
          duration_ms:pageDuration(),
          page_started_at:String(window.__capgoWebViewSessionStartedAt)
        });
      },true);
      document.addEventListener('deviceready',scheduleFlush,false);
      setTimeout(scheduleFlush,0);
    })();
    """

    private var installed = false

    /// Injects the reporter into every document. Reports reach the engine through
    /// the `reportWebViewError` plugin method.
    func install(on webView: WKWebView?) {
        guard !installed, let webView else {
            return
        }
        installed = true
        let userScript = WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView.configuration.userContentController.addUserScript(userScript)
        webView.evaluateJavaScript(Self.script, completionHandler: nil)
    }
}
