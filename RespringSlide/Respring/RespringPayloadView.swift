import SwiftUI
import WebKit

/// Runs the locally embedded WebKit respring technique after the user confirms.
/// There are no network requests and no external page is loaded.
struct RespringPayloadView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.loadHTMLString(RespringPayload.document, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The document is loaded exactly once in makeUIView.
    }
}

private enum RespringPayload {
    /// Based on the WebKit/iframe technique publicly attributed to neonmodder123
    /// and reimplemented in Swift in jailbreak.party's open-source tooling.
    /// A 15-second watchdog stops the pressure loop if SpringBoard does not restart.
    static let document = #"""
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
      <meta name="color-scheme" content="dark">
      <style>html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}</style>
    </head>
    <body>
      <iframe id="frame" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
      <script>
        const frame = document.getElementById('frame');
        const respringScript = `
          <html>
          <body>
          <script>
            const container = document.createElement('div');
            container.style.cssText = 'perspective: 1px; perspective-origin: 9999999% 9999999%;';
            document.body.appendChild(container);

            for (let i = 0; i < 500; i++) {
              const layer = document.createElement('div');
              layer.style.cssText = 'position:absolute;width:100vw;height:100vh;backdrop-filter:blur(100px);-webkit-backdrop-filter:blur(100px);transform:translate3d(100000px,100000px,' + i + 'px) rotateY(90deg);';
              container.appendChild(layer);
            }

            const pressureLoop = setInterval(() => {
              navigator.share({ title: 'R', text: 'R'.repeat(100000) }).catch(() => {});
              const bytes = new Uint8Array(1024 * 1024 * 10);
              crypto.getRandomValues(bytes);
            }, 0);

            // Failsafe: do not keep the stress loop running indefinitely.
            setTimeout(() => clearInterval(pressureLoop), 15000);
          <\/script>
          </body>
          </html>
        `;
        frame.srcdoc = respringScript;
      </script>
    </body>
    </html>
    """#
}
