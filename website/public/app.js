(() => {
  'use strict';
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const root = document.documentElement;
  const hero = document.querySelector('.hero');
  // One document entrance only; scroll-driven logo changes never reset it.
  if (hero && !reduced.matches && scrollY < 1) root.classList.add('hero-intro-pending');
  let introFallback;
  function revealHero(animate = false) {
    if (!root.classList.contains('hero-intro-pending')) return;
    clearTimeout(introFallback);
    root.classList.remove('hero-intro-pending');
    if (animate && !reduced.matches) root.classList.add('hero-intro-ready');
  }
  // Keep the copy available if the artwork or graphics context cannot load.
  introFallback = setTimeout(() => revealHero(), 5000);
  hero?.addEventListener('focusin', () => revealHero());
  addEventListener('scroll', () => { if (scrollY > 0) revealHero(); }, {passive:true});
  reduced.addEventListener('change', () => { if (reduced.matches) revealHero(); });
  const renderers = new Map();
  const visibilityHandlers = new Map();
  const visible = new Set();
  let frame = 0;
  let last = 0;
  let time = 0;

  // One shared, capped clock. Offscreen and background animations do no work.
  function tick(now) {
    frame = 0;
    if (document.hidden || reduced.matches || !visible.size) return;
    if (now - last >= 1000 / 30) {
      time += Math.min((now - last) / 1000, 0.05);
      last = now;
      visible.forEach(element => renderers.get(element)?.(time));
    }
    frame = requestAnimationFrame(tick);
  }
  function sync() {
    cancelAnimationFrame(frame);
    frame = 0;
    last = performance.now();
    if (reduced.matches) renderers.forEach(render => render(1.1));
    else if (!document.hidden && visible.size) frame = requestAnimationFrame(tick);
  }
  const visibility = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      entry.isIntersecting ? visible.add(entry.target) : visible.delete(entry.target);
      visibilityHandlers.get(entry.target)?.(entry.isIntersecting);
    });
    sync();
  });
  function register(element, render, onVisibility) {
    renderers.set(element, render);
    if (onVisibility) visibilityHandlers.set(element, onVisibility);
    render(reduced.matches ? 1.1 : 0);
    visibility.observe(element);
  }
  document.addEventListener('visibilitychange', sync);
  reduced.addEventListener('change', sync);

  const running = new Set();
  function settleLogos() {
    running.forEach(animation => animation.cancel());
    running.clear();
    revealHero();
  }
  document.addEventListener('visibilitychange', () => { if (document.hidden) settleLogos(); });
  reduced.addEventListener('change', () => { if (reduced.matches) settleLogos(); });
  document.querySelectorAll('.logo-stage').forEach(async stage => {
    const pieces = [...stage.querySelectorAll('.logo-piece')];
    const opening = !!stage.closest('.hero');
    try {
      await Promise.all(pieces.map(piece => piece.decode()));
      const observer = new IntersectionObserver(entries => {
        if (!entries.some(entry => entry.isIntersecting)) return;
        observer.disconnect();
        if (reduced.matches || document.hidden || !pieces[0].animate) {
          if (opening) revealHero();
          return;
        }
        stage.classList.add('is-animated');
        pieces.forEach((piece, index) => {
          const animation = piece.animate([
            {transform:`translate(${index ? 30 : -30}px,-20px)`, opacity:0},
            {transform:'translate(0,0)', opacity:1}
          ], {duration:1200, delay:index * 144, easing:'cubic-bezier(.22,.75,.18,1)', fill:'backwards'});
          running.add(animation);
          animation.finished.then(() => running.delete(animation), () => running.delete(animation));
        });
        if (opening) setTimeout(() => revealHero(true), 504);
      }, {threshold:0.15});
      observer.observe(stage);
    } catch {
      if (opening) revealHero();
    }
  });

  const canvas = document.querySelector('.stars');
  const context = canvas?.getContext('2d');
  if (context) {
    const points = Array.from({length:420}, (_,i) => ({x:(i*.61803398875)%1,y:(i*.41421356237)%1,r:.35+(i%4)*.17,phase:i*.7}));
    let width = 0, height = 0;
    const draw = seconds => {
      context.clearRect(0,0,width,height);
      points.forEach(point => {
        const y = (point.y * height + seconds * 1.3) % height;
        const edge = Math.sin(Math.PI*y/height);
        context.fillStyle = `rgba(210,216,229,${(.09+.12*(.5+.5*Math.sin(seconds*.35+point.phase)))*edge})`;
        context.beginPath(); context.arc(point.x*width,y,point.r,0,Math.PI*2); context.fill();
      });
    };
    new ResizeObserver(() => {
      width=canvas.clientWidth; height=canvas.clientHeight;
      const dpr=Math.min(devicePixelRatio,1.5);
      canvas.width=Math.round(width*dpr); canvas.height=Math.round(height*dpr);
      context.setTransform(dpr,0,0,dpr,0,0); draw(time);
    }).observe(canvas);
    register(canvas,draw);
  }
  if (!reduced.matches) {
    const reveals = new IntersectionObserver(entries => {
      entries.forEach(entry => { if(entry.isIntersecting){ entry.target.classList.add('visible'); reveals.unobserve(entry.target); } });
    }, {threshold:.1});
    document.querySelectorAll('.reveal').forEach(element => reveals.observe(element));
    document.documentElement.classList.add('motion-ready');
  }
})();
