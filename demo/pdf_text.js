// Extracts positioned text from a PDF bank statement using pdf.js (Apache-2.0,
// bundled in ./pdfjs). Loaded on demand; Dart lays the text out into rows.
(function () {
  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = new URL(src, document.baseURI).toString();
      s.onload = resolve;
      s.onerror = function () { reject(new Error('pdfjs_load_failed')); };
      document.head.appendChild(s);
    });
  }

  async function ensurePdfJs() {
    if (!window.pdfjsLib) {
      await loadScript('pdfjs/pdf.min.js');
      window.pdfjsLib.GlobalWorkerOptions.workerSrc = new URL('pdfjs/pdf.worker.min.js', document.baseURI).toString();
    }
    return window.pdfjsLib;
  }

  // Returns JSON: [[page, x, y, width, text], ...]
  // Rejects with 'needs_password' / 'wrong_password' / other message.
  window.dkPdfText = async function (bytes, password) {
    var lib = await ensurePdfJs();
    var doc;
    try {
      doc = await lib.getDocument({ data: bytes, password: password || undefined }).promise;
    } catch (e) {
      if (e && e.name === 'PasswordException') {
        throw new Error(e.code === 2 ? 'wrong_password' : 'needs_password');
      }
      throw new Error('pdf_unreadable');
    }
    var out = [];
    for (var p = 1; p <= doc.numPages; p++) {
      var page = await doc.getPage(p);
      var tc = await page.getTextContent();
      for (var i = 0; i < tc.items.length; i++) {
        var it = tc.items[i];
        if (!it.str || !it.str.trim()) continue;
        out.push([p, it.transform[4], it.transform[5], it.width || 0, it.str]);
      }
    }
    return JSON.stringify(out);
  };
})();
