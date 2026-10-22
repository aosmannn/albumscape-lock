//
//  YouTubeEmbed.swift
//  Albumscape
//

import SwiftUI
import WebKit

/// A muted, chrome-free YouTube player that covers its frame. YouTube refuses embeds from a page with no
/// https origin, so the page is loaded with a real base URL. `onReady` fires when playback starts,
/// `onFailure` when YouTube refuses to play it (embedding off, removed, region-locked).
struct YouTubeEmbed: NSViewRepresentable {
    let video: YouTubeVideo
    let startAt: TimeInterval
    /// Whether the song is playing, and where it is (already shifted to the video's clock), so the video pauses and
    /// resumes with it instead of showing YouTube's own pause symbol over the picture.
    var playing = true
    var position: () -> TimeInterval = { 0 }
    /// Seconds left in the song, so the video knows whether to repeat a part of itself or fade away when it runs out.
    var songRemaining: () -> TimeInterval = { 999 }
    var onReady: () -> Void = {}
    var onFailure: () -> Void = {}
    var onHide: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(context.coordinator, name: "yt")
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onReady = onReady
        context.coordinator.onFailure = onFailure
        context.coordinator.onHide = onHide
        if context.coordinator.loaded == video.id { view.evaluateJavaScript("songLeft(\(Int(songRemaining())))", completionHandler: nil) }
        if context.coordinator.loaded == video.id, context.coordinator.lastPlaying != playing {
            context.coordinator.lastPlaying = playing
            view.evaluateJavaScript("setPlaying(\(playing), \(max(0, position())))", completionHandler: nil)
        }
        guard context.coordinator.loaded != video.id else { return }
        context.coordinator.lastPlaying = playing
        context.coordinator.loaded = video.id
        view.loadHTMLString(Self.page(id: video.id, start: max(0, startAt + video.offset)),
                            baseURL: URL(string: "https://albumscape.vercel.app"))
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        view.loadHTMLString("", baseURL: nil)  // stops the audio-less playback
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loaded: String?
        var lastPlaying = true
        var onReady: () -> Void = {}
        var onFailure: () -> Void = {}
        var onHide: () -> Void = {}

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.body as? String {
            case "ready": DispatchQueue.main.async { self.onReady() }
            case "hide": DispatchQueue.main.async { self.onHide() }
            case "error": DispatchQueue.main.async { self.onFailure() }
            default: break
            }
        }
    }

    /// Two players take turns. Shortly before the video ends a second one starts hidden from the beginning, and once it is
    /// playing the two cross-fade, so YouTube never gets to draw its end screen ("up next", replay). It is the same trick
    /// the Windows Albumscape uses.
    private static func page(id: String, start: TimeInterval) -> String {
        """
        <!doctype html><html><head><meta name="referrer" content="strict-origin-when-cross-origin"><style>
        html,body{margin:0;height:100%;overflow:hidden;background:#000}
        body{transition:opacity .3s ease}
        .p{position:absolute;top:50%;left:50%;width:177.78vh;min-width:100vw;height:56.25vw;min-height:100vh;
           transform:translate(-50%,-50%) scale(1.15);pointer-events:none;opacity:0;transition:opacity .9s ease}
        .p.on{opacity:1}
        </style></head><body><div id="a" class="p"><div id="pa"></div></div><div id="b" class="p"><div id="pb"></div></div><script>
        var t=document.createElement('script');t.src='https://www.youtube.com/iframe_api';document.head.appendChild(t);
        function send(m){window.webkit.messageHandlers.yt.postMessage(m)}
        function noCaptions(p){try{p.unloadModule('captions');p.unloadModule('cc');p.setOption('captions','track',{})}catch(x){}}
        var liveTimer=null;
        var cur=null,slot='a',switching=false,wantPlaying=true,first=false;
        function build(which,from,onPlaying){
          document.getElementById(which).innerHTML='<div id="p'+which+'"></div>';
          return new YT.Player('p'+which,{width:'100%',height:'100%',videoId:'\(id)',playerVars:{autoplay:1,mute:1,controls:0,
            disablekb:1,fs:0,modestbranding:1,rel:0,iv_load_policy:3,playsinline:1,cc_load_policy:0,start:Math.floor(from)},
            events:{onReady:function(e){e.target.mute();e.target.playVideo();noCaptions(e.target)},
              onStateChange:function(e){
                if(e.data===1){noCaptions(e.target);if(onPlaying)onPlaying(e.target)}
                else if(e.target===cur&&!switching&&e.data!==-1){clearTimeout(liveTimer);send('hide')}  // loading, paused, ended: back to the cover
                if(e.data===0){e.target.seekTo(0);e.target.playVideo()}  // only if the hand-over was too late
              },
              onError:function(){send('error')}}});
        }
        function onYouTubeIframeAPIReady(){
          cur=build('a',\(Int(start)),function(){
            if(!first){first=true;document.getElementById('a').classList.add('on')}
            // YouTube draws its own title, spinner and pause screen whenever the video starts or loads (about 4 s). The
            // cover (or the animated cover) stays on screen until the video has been playing steadily, as on Windows.
            clearTimeout(liveTimer);liveTimer=setTimeout(function(){if(cur&&!switching)send('ready')},4500);
          });
          setInterval(tick,300);
        }
        var songLeftS=999,faded=false;
        function songLeft(n){songLeftS=n}
        function tick(){
          if(!cur||switching||faded||!wantPlaying||!first)return;
          try{
            var d=cur.getDuration(),t=cur.getCurrentTime(),left=d-t;
            if(d>0&&left<11){
              // The video is about to run out (before YouTube draws its "up next" squares). If the song goes on for a while,
              // carry on with a part of the video from a quarter of the way in; if it is nearly over, fade to the cover.
              if(songLeftS>left+8)handOver(d*0.25);else fadeAway();
            }
          }catch(x){}
        }
        function fadeAway(){
          faded=true;document.body.style.transition='opacity 1.6s ease';document.body.style.opacity=0;
        }
        function handOver(from){
          switching=true;
          var next=slot==='a'?'b':'a',old=cur,oldSlot=slot,live=false,np=null;
          np=build(next,from,function(){
            if(live)return;live=true;
            setTimeout(function(){  // once YouTube's own start-of-video overlay has passed
              document.getElementById(next).classList.add('on');document.getElementById(oldSlot).classList.remove('on');
              setTimeout(function(){try{old.destroy()}catch(x){}cur=np;slot=next;switching=false},1000);
            },4600);
          });
        }
        var pauseTimer=null,showTimer=null;
        // The page itself goes dark before the video is paused and stays dark until the play flash has passed, so
        // YouTube's own pause and play symbols are never on screen (the cover shows through instead).
        function setPlaying(p,seek){
          wantPlaying=p;if(!cur||switching)return;
          clearTimeout(pauseTimer);clearTimeout(showTimer);
          if(!p){
            document.body.style.opacity=0;
            pauseTimer=setTimeout(function(){try{cur.pauseVideo()}catch(x){}},320);
          }else{
            try{cur.seekTo(seek,true);cur.playVideo()}catch(x){}
            if(!faded)showTimer=setTimeout(function(){document.body.style.opacity=1},1200);
          }
        }
        </script></body></html>
        """
    }
}
