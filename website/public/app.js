(() => {
  'use strict';
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const clamp = value => Math.min(1, Math.max(0, value));

  // Each story is a tall section with a pinned stage. Its first stretch is
  // the intro (written to --q for the CSS transforms); the rest is split
  // evenly between the steps, which swap screens and captions.
  const stories = [...document.querySelectorAll('.story')].map(section => {
    const steps = Number(section.dataset.steps) || 1;
    const groups = ['.shot', '.captions li', '.ambient img', '.progress span'].map(selector => [...section.querySelectorAll(selector)]);
    const videos = [...section.querySelectorAll('video.shot')];
    return {section, steps, groups, videos, step: 0, q: -1, visible: false};
  });

  // The outgoing screen stays opaque underneath while the next one fades in on
  // top, so nothing behind them ever shows through.
  function setStep(story, step) {
    if (story.step === step) return;
    const previous = story.step;
    story.step = step;
    story.groups.forEach((group, kind) => group.forEach((element, index) => {
      element.classList.toggle('is-active', index === step);
      if (kind === 0) element.classList.toggle('was-active', index === previous);
    }));
  }

  function syncVideos(story) {
    // The Apple TV clip is the hero, so it plays from the top of the page; the
    // phone clip waits until the phone has risen into view.
    const ready = story.section.classList.contains('story-tv') || story.q > .5;
    const play = ready && story.visible && !document.hidden && !reduced.matches;
    story.videos.forEach(video => {
      const active = play && Number(video.dataset.step) === story.step;
      if (active && video.paused) {
        if (video.preload === 'none') video.preload = 'auto';
        video.play().catch(() => {});
      } else if (!active && !video.paused) {
        video.pause();
      }
    });
  }

  function update() {
    frame = 0;
    const height = innerHeight;
    stories.forEach(story => {
      const rect = story.section.getBoundingClientRect();
      const distance = rect.height - height;
      const progress = distance > 0 ? clamp(-rect.top / distance) : 0;
      const intro = story.section.classList.contains('story-tv') ? .2 : .26;
      // With Reduce Motion, the intro cuts between its start and end layouts
      // halfway through instead of zooming and rising with the scroll.
      const q = reduced.matches ? (progress / intro >= .5 ? 1 : 0) : clamp(progress / intro);
      if (Math.abs(q - story.q) > .0005) {
        story.q = q;
        story.section.style.setProperty('--q', q.toFixed(4));
      }
      const into = (progress - intro) / (1 - intro);
      setStep(story, into <= 0 ? 0 : Math.min(story.steps - 1, Math.floor(into * story.steps * 1.12)));
      syncVideos(story);
    });
    nav?.classList.toggle('is-scrolled', scrollY > 8);
  }

  let frame = 0;
  const schedule = () => { if (!frame) frame = requestAnimationFrame(update); };
  const nav = document.querySelector('.nav');
  addEventListener('scroll', schedule, {passive:true});
  addEventListener('resize', schedule);
  document.addEventListener('visibilitychange', schedule);
  reduced.addEventListener('change', schedule);

  // Only stories near the viewport play video; the phone clip loads as its
  // section approaches.
  const nearby = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      const story = stories.find(item => item.section === entry.target);
      if (!story) return;
      story.visible = entry.isIntersecting;
      // Decode every screen before the section arrives, not as each step starts.
      if (story.visible && !story.decoded) {
        story.decoded = true;
        story.section.querySelectorAll('img').forEach(image => {
          image.loading = 'eager';
          image.decode?.().catch(() => {});
        });
      }
    });
    schedule();
  }, {rootMargin:'50% 0px'});
  stories.forEach(story => nearby.observe(story.section));
  update();

  // The Spotlight banners only drift while they're on screen.
  const marquee = document.querySelector('.marquee');
  if (marquee) {
    marquee.classList.add('is-paused');
    new IntersectionObserver(([entry]) => marquee.classList.toggle('is-paused', !entry.isIntersecting)).observe(marquee);
  }

  // Sections rise into place once as they arrive.
  if (!reduced.matches && 'IntersectionObserver' in window) {
    const reveals = new IntersectionObserver(entries => {
      entries.forEach(entry => { if (entry.isIntersecting) { entry.target.classList.add('visible'); reveals.unobserve(entry.target); } });
    }, {threshold:.15});
    document.querySelectorAll('.reveal').forEach(element => {
      const siblings = [...element.parentElement.children].filter(child => child.classList.contains('reveal'));
      const delay = siblings.indexOf(element) * 80;
      if (delay) element.style.transitionDelay = `${delay}ms`;
      reveals.observe(element);
    });
    document.documentElement.classList.add('motion-ready');
  }

  // The approved Glide entrance: the logo's two pieces slide into place once.
  const running = new Set();
  const settleLogos = () => running.forEach(animation => animation.finish());
  document.addEventListener('visibilitychange', () => { if (document.hidden) settleLogos(); });
  reduced.addEventListener('change', () => { if (reduced.matches) settleLogos(); });
  document.querySelectorAll('.logo-stage').forEach(async stage => {
    const pieces = [...stage.querySelectorAll('.logo-piece')];
    try {
      await Promise.all(pieces.map(piece => piece.decode()));
    } catch {
      return;
    }
    const observer = new IntersectionObserver(entries => {
      if (!entries.some(entry => entry.isIntersecting)) return;
      observer.disconnect();
      if (reduced.matches || document.hidden || !pieces[0].animate) return;
      stage.classList.add('is-animated');
      pieces.forEach((piece, index) => {
        const animation = piece.animate([
          {transform:`translate(${index ? 30 : -30}px,-20px)`, opacity:0},
          {transform:'translate(0,0)', opacity:1}
        ], {duration:1200, delay:index * 144, easing:'cubic-bezier(.22,.75,.18,1)', fill:'backwards'});
        running.add(animation);
        animation.finished.then(() => running.delete(animation), () => running.delete(animation));
      });
    }, {threshold:.15});
    observer.observe(stage);
  });
})();
