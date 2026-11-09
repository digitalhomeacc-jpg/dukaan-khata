{{flutter_js}}
{{flutter_build_config}}

// Our own offline service worker (app_sw.js) replaces Flutter's deprecated one.
_flutter.loader.load({
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    await appRunner.runApp();
    const s = document.getElementById('splash');
    if (s) {
      s.style.opacity = '0';
      setTimeout(function () { s.remove(); }, 300);
    }
  },
});
