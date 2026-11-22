/// スマホのブラウザに返すリモコン画面。
///
/// SwiftPM のリソースは使わず文字列で内蔵する（make-app.sh はバイナリだけをコピーするため）。
/// 会場にネットが無くても動くよう、外部リソース（CDN・Webフォント・画像）は一切使わない。
enum RemotePage {
    static let html = #"""
<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="theme-color" content="#171717">
<meta name="format-detection" content="telephone=no">
<title>リモコン</title>
<style>
  :root {
    --bg: #171717;
    --fg: #f2f2f2;
    --sub: #8a8a8a;
    --next: #2f6fed;
    --next-press: #2457bd;
    --prev: #2b2b2b;
    --prev-press: #3a3a3a;
    --alert: #d64545;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body {
    position: fixed;
    inset: 0;
    width: 100%;
    height: 100dvh;
    overflow: hidden;
    overscroll-behavior: none;
    background: var(--bg);
    color: var(--fg);
    font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Noto Sans JP", sans-serif;
    -webkit-user-select: none;
    user-select: none;
    -webkit-touch-callout: none;
    -webkit-tap-highlight-color: transparent;
    -webkit-text-size-adjust: 100%;
    touch-action: manipulation;
  }
  main {
    height: 100%;
    display: grid;
    /* 時計の行・縮小画像の行・戻る・次へ。「次へ」は画面の高さの半分以上を必ず取る */
    grid-template-rows: auto auto minmax(40px, 1fr) 52dvh;
    gap: 10px;
    padding:
      calc(env(safe-area-inset-top) + 12px)
      calc(env(safe-area-inset-right) + 14px)
      calc(env(safe-area-inset-bottom) + 14px)
      calc(env(safe-area-inset-left) + 14px);
  }
  header {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 12px;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
  /* 時計が最上段の主役。ページ番号より明確に大きく */
  #clock {
    font-size: clamp(44px, 17.5vw, 72px);
    font-weight: 600;
    line-height: 1;
    letter-spacing: -.01em;
  }
  #page {
    font-size: clamp(20px, 7vw, 30px);
    font-weight: 600;
    transition: opacity .2s;
  }
  #page .total { color: var(--sub); }

  /* 縮小画像の行：左に今（大）、右に次（小）。幅はおよそ 3:2、枠は16:9基準 */
  #media {
    position: relative;
    height: min(calc((100vw - 36px) * 0.6 * 0.5625), 18dvh);
  }
  .thumbs {
    display: grid;
    grid-template-columns: 3fr 2fr;
    gap: 8px;
    height: 100%;
    pointer-events: none;
  }
  .frame {
    position: relative;
    background: #0b0b0b;
    border-radius: 8px;
    overflow: hidden;
  }
  /* 今のスライドだけは触れる（指を置くとポインター）。「次」は従来どおり触っても何も起きない */
  #thumb-current { height: 100%; pointer-events: auto; touch-action: none; }

  /* ポインター中：今のスライドを画面幅いっぱいの16:9に拡大して上に重ねる（他の配置は動かさない） */
  #zoom {
    display: none;
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    aspect-ratio: 16 / 9;
    z-index: 10;
    background: #0b0b0b;
    border-radius: 10px;
    overflow: hidden;
    box-shadow: 0 8px 30px rgba(0, 0, 0, .6);
    pointer-events: none;
  }
  #zoom img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: contain; }
  .laser {
    position: absolute;
    width: 16px;
    height: 16px;
    margin: -8px 0 0 -8px;
    border-radius: 50%;
    background: #ff2219;
    border: 1.5px solid rgba(255, 255, 255, .95);
    box-shadow: 0 0 10px 3px rgba(255, 30, 20, .6);
  }
  body.pointing #zoom { display: block; }
  body.pointing #prev { pointer-events: none; }
  #thumb-next { width: 100%; aspect-ratio: 16 / 9; max-height: 100%; align-self: start; }
  .frame img {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: contain;
    opacity: 0;
    -webkit-user-drag: none;
  }
  .frame img.shown { opacity: 1; }
  .frame .end {
    display: none;
    position: absolute;
    inset: 0;
    align-items: center;
    justify-content: center;
    color: #5a5a5a;
    font-size: 13px;
    font-weight: 600;
    letter-spacing: .08em;
  }
  .frame.end .end { display: flex; }
  #alert {
    display: none;
    position: absolute;
    inset: 0;
    align-items: center;
    justify-content: center;
    border-radius: 12px;
    background: var(--alert);
    font-size: clamp(18px, 6vw, 26px);
    font-weight: 600;
    white-space: nowrap;
  }
  button {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 100%;
    height: 100%;
    border: 0;
    border-radius: 22px;
    color: var(--fg);
    font: inherit;
    touch-action: manipulation;
    cursor: pointer;
    transition: transform .08s, background-color .08s, opacity .2s;
  }
  button svg { width: 34%; max-width: 160px; height: auto; fill: none; stroke: currentColor; stroke-width: 3; stroke-linecap: round; stroke-linejoin: round; pointer-events: none; }
  #prev { background: var(--prev); }
  #prev svg { width: 18%; max-width: 64px; }
  #next { background: var(--next); }
  #prev.pressed { background: var(--prev-press); transform: scale(.97); }
  #next.pressed { background: var(--next-press); transform: scale(.98); }
  button.edge { opacity: .3; }

  /* つながっていない・合言葉が無効なとき：縮小画像の行を赤い帯のメッセージに置き換え（古い画像は当てにならないので隠す）、
     ページ番号とボタンを沈ませる。時計は通信に関係ないのでそのまま */
  body.offline .thumbs { visibility: hidden; }
  body.offline #alert { display: flex; }
  body.offline #page { opacity: .3; }
  body.offline button { opacity: .35; }
</style>
</head>
<body>
<main>
  <header>
    <div id="clock">–</div>
    <div id="page" aria-live="polite"><span id="current">–</span><span class="total"> / <span id="total">–</span></span></div>
  </header>
  <div id="media">
    <div class="thumbs" aria-hidden="true">
      <div class="frame" id="thumb-current"><img alt="" draggable="false"><div class="end">END</div></div>
      <div class="frame" id="thumb-next"><img alt="" draggable="false"><div class="end">END</div></div>
    </div>
    <div id="alert" role="status">接続できません</div>
    <div id="zoom" aria-hidden="true"><img alt="" draggable="false"><div class="laser"></div></div>
  </div>
  <button id="prev" type="button" aria-label="前のスライドへ戻る">
    <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7"/></svg>
  </button>
  <button id="next" type="button" aria-label="次のスライドへ進む">
    <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5l7 7-7 7"/></svg>
  </button>
</main>
<script>
(() => {
  const base = location.pathname.replace(/\/+$/, '');
  const currentEl = document.getElementById('current');
  const totalEl = document.getElementById('total');
  const prevBtn = document.getElementById('prev');
  const nextBtn = document.getElementById('next');

  // 応答の順序が入れ替わっても古い番号で上書きしないよう、送った順に番号を振る
  let sequence = 0;
  let applied = 0;
  let polling = null;
  let pollInFlight = false;

  function request(method, path) {
    const id = ++sequence;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);
    return fetch(base + path, { method, cache: 'no-store', signal: controller.signal })
      .then(res => {
        if (!res.ok) {
          const error = new Error('HTTP ' + res.status);
          error.status = res.status;
          throw error;
        }
        return res.json();
      })
      .then(state => {
        setStatus('ok', id);
        if (id > applied) {
          applied = id;
          render(state);
        }
      })
      // 404 はアプリの再起動で合言葉が変わった（古いURLを開いたまま）とき。それ以外は通信の問題として扱う
      .catch(error => setStatus(error && error.status === 404 ? 'stale' : 'offline', id))
      .finally(() => clearTimeout(timer));
  }

  function render(state) {
    // PDFが開き直されたら、前のPDFの画像は全部捨てる
    if (state.doc !== currentDoc) {
      resetImages();
      currentDoc = state.doc;
    }
    currentEl.textContent = state.page;
    totalEl.textContent = state.total;
    prevBtn.classList.toggle('edge', state.page <= 1);
    nextBtn.classList.toggle('edge', state.page >= state.total);

    // 画像は後追い。ページ番号とボタンは画像を待たない
    showSlot(slots.current, state.doc, state.page);
    showSlot(slots.next, state.doc, state.page < state.total ? state.page + 1 : 0);
    if (state.page + 2 <= state.total) loadSlide(state.doc, state.page + 2);  // 1枚先を先読み
  }

  // ---- 縮小画像 ----
  // 取得済みの画像は objectURL としてメモリに持つ（「次」が「今」に移るとき取り直さない）。
  // Map の並び＝使った順。上限を超えたら古いものから解放する
  const MAX_IMAGES = 8;
  let currentDoc = null;
  const images = new Map();   // "doc:page" -> objectURL
  const loading = new Map();  // "doc:page" -> Promise<objectURL|null>

  function slideKey(doc, page) { return doc + ':' + page; }

  function useImage(key) {
    const url = images.get(key);
    if (url !== undefined) { images.delete(key); images.set(key, url); }
    return url;
  }

  function remember(key, url) {
    images.delete(key);
    images.set(key, url);
    while (images.size > MAX_IMAGES) {
      const [oldKey, oldUrl] = images.entries().next().value;
      images.delete(oldKey);
      URL.revokeObjectURL(oldUrl);
    }
  }

  function resetImages() {
    for (const url of images.values()) URL.revokeObjectURL(url);
    images.clear();
    loading.clear();
    for (const slot of Object.values(slots)) clearSlot(slot);
  }

  function loadSlide(doc, page) {
    const key = slideKey(doc, page);
    const cached = useImage(key);
    if (cached !== undefined) return Promise.resolve(cached);
    if (loading.has(key)) return loading.get(key);

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    const promise = fetch(base + '/slide/' + page + '?d=' + doc, { cache: 'no-store', signal: controller.signal })
      .then(res => {
        if (!res.ok) throw new Error('HTTP ' + res.status);
        return res.blob();
      })
      .then(blob => {
        // 待っている間にPDFが変わっていたら捨てる
        if (doc !== currentDoc) return null;
        const url = URL.createObjectURL(blob);
        remember(key, url);
        return url;
      })
      .catch(() => null)
      .finally(() => {
        clearTimeout(timer);
        if (loading.get(key) === promise) loading.delete(key);
      });
    loading.set(key, promise);
    return promise;
  }

  function makeSlot(id) {
    const frame = document.getElementById(id);
    const img = frame.querySelector('img');
    const slot = { frame, img, want: null };
    img.addEventListener('load', () => {
      if (!img.getAttribute('src')) return;
      img.classList.add('shown');
      // ポインター中に別の指でページが進んだら、拡大表示も新しいページの画像にする（点はそのまま）
      if (id === 'thumb-current' && pointerId !== null) zoomImg.src = img.src;
    });
    return slot;
  }
  const slots = { current: makeSlot('thumb-current'), next: makeSlot('thumb-next') };

  function clearSlot(slot) {
    slot.want = null;
    slot.img.classList.remove('shown');
    slot.img.removeAttribute('src');
    slot.frame.classList.remove('end');
  }

  // page が 0 なら最後のページの先（END）。表示したい画像を slot.want に覚え、遅れて届いた古い画像では上書きしない
  function showSlot(slot, doc, page) {
    const key = page ? slideKey(doc, page) : 'end';
    if (slot.want === key) return;
    clearSlot(slot);  // 古いページの画像を新しいページ番号の下に残さない
    slot.want = key;
    if (!page) {
      slot.frame.classList.add('end');
      return;
    }
    const cached = useImage(key);
    if (cached !== undefined) {
      slot.img.src = cached;
      return;
    }
    loadSlide(doc, page).then(url => {
      if (slot.want !== key) return;
      if (url) slot.img.src = url;
      else slot.want = null;  // 取れなかったら、次の同期でもう一度取りに行く
    });
  }

  // 接続状態も、より新しい要求の結果だけを反映する（'ok' / 'offline' / 'stale'＝合言葉が無効）
  const offlineEl = document.getElementById('alert');
  let statusApplied = 0;
  function setStatus(status, id) {
    if (id < statusApplied) return;
    statusApplied = id;
    if (status !== 'ok') {
      offlineEl.textContent = status === 'stale' ? 'QRを読み直してください' : '接続できません';
    }
    document.body.classList.toggle('offline', status !== 'ok');
  }

  function poll() {
    if (pollInFlight) return;
    pollInFlight = true;
    request('GET', '/state').finally(() => { pollInFlight = false; });
  }

  function startPolling() {
    if (polling !== null) return;
    poll();
    polling = setInterval(poll, 1000);
  }

  function stopPolling() {
    if (polling === null) return;
    clearInterval(polling);
    polling = null;
  }

  // 押した瞬間に反応させる（タップは pointerdown、キーボード操作は click で拾う）
  function bind(button, path) {
    const act = () => request('POST', path);
    button.addEventListener('pointerdown', e => {
      e.preventDefault();
      button.classList.add('pressed');
      act();
    });
    const release = () => button.classList.remove('pressed');
    button.addEventListener('pointerup', release);
    button.addEventListener('pointercancel', release);
    button.addEventListener('pointerleave', release);
    button.addEventListener('click', e => { if (e.detail === 0) act(); });
  }
  bind(nextBtn, '/next');
  bind(prevBtn, '/prev');

  // ---- ポインター（今のスライドに指を置いている間、Macの投影と発表者ビューに赤い点を出す）----
  const thumbCurrent = document.getElementById('thumb-current');
  const zoomEl = document.getElementById('zoom');
  const zoomImg = zoomEl.querySelector('img');
  const laserEl = zoomEl.querySelector('.laser');
  let pointerId = null;      // 追っている指（最初の1本だけ）
  let pointerPos = null;     // 最新の位置 {x, y}（0〜1）
  let resendTimer = null;

  // 拡大表示された画像そのものの表示領域（object-fit: contain で収めた部分。枠ではない）
  function zoomContentRect() {
    const box = zoomEl.getBoundingClientRect();
    const src = slots.current.img;
    const nw = src.naturalWidth || 16, nh = src.naturalHeight || 9;
    const scale = Math.min(box.width / nw, box.height / nh);
    const width = nw * scale, height = nh * scale;
    return { box, left: box.left + (box.width - width) / 2, top: box.top + (box.height - height) / 2, width, height };
  }

  function trackPointer(e) {
    const r = zoomContentRect();
    const clamp = v => Math.min(1, Math.max(0, v));
    const x = clamp((e.clientX - r.left) / r.width);
    const y = clamp((e.clientY - r.top) / r.height);
    pointerPos = { x, y };
    laserEl.style.left = (r.left - r.box.left + x * r.width) + 'px';
    laserEl.style.top = (r.top - r.box.top + y * r.height) + 'px';
    queuePointer(pointerPos);
  }

  thumbCurrent.addEventListener('pointerdown', e => {
    e.preventDefault();
    if (pointerId !== null) return;
    // 画像がまだ無いとき・切断中（赤帯表示中）はポインターに入らない
    const img = slots.current.img;
    if (!img.classList.contains('shown') || !img.getAttribute('src') || document.body.classList.contains('offline')) return;
    pointerId = e.pointerId;
    try { thumbCurrent.setPointerCapture(e.pointerId); } catch (_) {}
    zoomImg.src = img.src;
    document.body.classList.add('pointing');
    trackPointer(e);
    // 指が止まっていても、置いている間は0.5秒ごとに送り直す（Mac側の自動消去に引っかからないように）
    resendTimer = setInterval(() => {
      if (pointerPos && performance.now() - lastPointerSend >= 450) queuePointer(pointerPos);
    }, 500);
  });
  thumbCurrent.addEventListener('pointermove', e => {
    if (e.pointerId !== pointerId) return;
    e.preventDefault();
    trackPointer(e);
  });
  function endPointer(e) {
    if (e.pointerId !== pointerId) return;
    pointerId = null;
    pointerPos = null;
    clearInterval(resendTimer);
    resendTimer = null;
    document.body.classList.remove('pointing');
    queuePointer({ off: true });  // 飛行中の要求が終わってから、必ず最後に送られる
  }
  thumbCurrent.addEventListener('pointerup', endPointer);
  thumbCurrent.addEventListener('pointercancel', endPointer);
  thumbCurrent.addEventListener('lostpointercapture', endPointer);

  // 送信の間引き：同時に飛ばすのは1本まで。待っている間に来た位置は最新の1つだけ残す（「消す」も最新扱いで上書き）。
  // 加えて1秒あたり40回まで。成否は接続状態の表示に影響させない
  const POINTER_MIN_INTERVAL = 25;
  let pointerPending = null;
  let pointerInFlight = false;
  let pointerWait = null;
  let lastPointerSend = 0;

  function queuePointer(message) {
    pointerPending = message;
    pumpPointer();
  }

  function pumpPointer() {
    if (pointerInFlight || pointerPending === null || pointerWait !== null) return;
    const wait = POINTER_MIN_INTERVAL - (performance.now() - lastPointerSend);
    if (wait > 0) {
      pointerWait = setTimeout(() => { pointerWait = null; pumpPointer(); }, wait);
      return;
    }
    const message = pointerPending;
    pointerPending = null;
    pointerInFlight = true;
    lastPointerSend = performance.now();
    const query = message.off ? 'off=1' : 'x=' + message.x.toFixed(4) + '&y=' + message.y.toFixed(4);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);
    fetch(base + '/pointer?' + query, { method: 'POST', cache: 'no-store', signal: controller.signal })
      .catch(() => {})
      .finally(() => {
        clearTimeout(timer);
        pointerInFlight = false;
        pumpPointer();
      });
  }

  document.addEventListener('contextmenu', e => e.preventDefault());
  document.addEventListener('touchmove', e => e.preventDefault(), { passive: false });
  document.addEventListener('gesturestart', e => e.preventDefault());

  // ---- 時計（スマホ自身の時刻。Macとの通信は使わない）----
  const clockEl = document.getElementById('clock');
  let clockTimer = null;
  function tickClock() {
    const now = new Date();
    clockEl.textContent = now.getHours() + ':' + String(now.getMinutes()).padStart(2, '0');
    // 次の分の変わり目に合わせて更新する
    clearTimeout(clockTimer);
    clockTimer = setTimeout(tickClock, 60000 - (now.getSeconds() * 1000 + now.getMilliseconds()) + 50);
  }
  tickClock();

  // 画面が見えている間だけ同期する（戻ってきたら時計もすぐ合わせ直す）
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      tickClock();
      startPolling();
    } else {
      stopPolling();
    }
  });
  if (document.visibilityState === 'visible') startPolling();
})();
</script>
</body>
</html>
"""#
}
