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

  const vertex = `attribute vec2 position; varying vec2 uv;
    void main(){uv=position*.5+.5;gl_Position=vec4(position,0.,1.);}`;
  const fragment = `
    #ifdef GL_FRAGMENT_PRECISION_HIGH
    precision highp float;
    #else
    precision mediump float;
    #endif
    uniform sampler2D mark; uniform float assembly; uniform float footprint; varying vec2 uv;
    float alpha(vec2 p){
      vec2 d=vec2(footprint*.25);
      return (texture2D(mark,p+d).a+texture2D(mark,p-d).a+
        texture2D(mark,p+vec2(d.x,-d.y)).a+texture2D(mark,p+vec2(-d.x,d.y)).a)*.25;
    }
    void main(){
      vec2 logoUV=(uv-.5)*1.5+.5;
      if(any(lessThan(logoUV,vec2(0.)))||any(greaterThan(logoUV,vec2(1.)))){gl_FragColor=vec4(0.);return;}
      vec4 original=texture2D(mark,logoUV);
      vec2 p=logoUV-vec2(.5,.51);
      float radius=length(p);
      // Fixed studio lighting keeps the silver finish still once assembled.
      float reflection=(p.x*.75+p.y)*7.+.4;
      float shine=pow(max(0.,sin(reflection)),10.);
      float soft=.5+.5*sin(reflection-1.);
      float bevel=clamp((1.-alpha(logoUV+vec2(.004,.006)))+
        (1.-alpha(logoUV-vec2(.004,.006))),0.,1.);
      float material=dot(original.rgb,vec3(.333));
      float metal=.13+material*.7+soft*.18+shine*.5+bevel*.48;
      float grain=fract(sin(dot(floor(logoUV*180.),vec2(12.9898,78.233)))*43758.5453);
      float arrival=radius*.3+grain*.14;
      float reveal=smoothstep(.40+arrival,.62+arrival,assembly);
      float wash=sin(clamp((assembly-.46)/.54,0.,1.)*3.14159)*.5;
      float opacity=alpha(logoUV)*reveal;
      gl_FragColor=vec4(vec3(metal+wash)*vec3(.975,.985,1.)*opacity,opacity);
    }`;
  const particleVertex = `attribute vec2 home; attribute vec3 scatter;
    uniform float assembly; uniform float pixels; uniform float pointLimit; uniform float travel;
    varying float strength;
    void main(){
      float loose=1.-assembly;
      float angle=scatter.z+loose*1.8+travel*.6;
      vec2 orbit=vec2(cos(angle),sin(angle));
      vec2 position=home+orbit*scatter.x*loose;
      gl_Position=vec4(position/1.5,0.,1.);
      gl_PointSize=min(pointLimit,(1.5+loose*scatter.y*9.)*pixels/640.);
      strength=(1.-smoothstep(.72,1.,assembly))*(.45+.4*scatter.y);
    }`;
  const particleFragment = `precision mediump float; varying float strength;
    void main(){
      float r=length(gl_PointCoord-.5)*2.;
      float glow=exp(-r*r*5.)*(1.-smoothstep(.65,1.,r))*strength;
      gl_FragColor=vec4(vec3(.94,.97,1.)*glow,glow);
    }`;
  function animateLogo(stage) {
    const canvas = stage.querySelector('canvas');
    const img = stage.querySelector('img');
    const gl = canvas.getContext('webgl', {alpha:true, antialias:false, depth:false, powerPreference:'low-power'});
    if (!gl) { if (stage.closest('.hero')) revealHero(); return; }
    function shader(type, source) {
      const s = gl.createShader(type);
      gl.shaderSource(s, source); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { gl.deleteShader(s); throw new Error('Logo shader unavailable'); }
      return s;
    }
    try {
      function makeProgram(vertexSource, fragmentSource) {
        const program=gl.createProgram();
        const vs=shader(gl.VERTEX_SHADER,vertexSource), fs=shader(gl.FRAGMENT_SHADER,fragmentSource);
        gl.attachShader(program,vs); gl.attachShader(program,fs); gl.linkProgram(program);
        gl.deleteShader(vs); gl.deleteShader(fs);
        if(!gl.getProgramParameter(program,gl.LINK_STATUS)) throw new Error('Logo program unavailable');
        return program;
      }
      const program = makeProgram(vertex,fragment);
      gl.useProgram(program);
      const buffer = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1]), gl.STATIC_DRAW);
      const position = gl.getAttribLocation(program,'position');
      gl.enableVertexAttribArray(position); gl.vertexAttribPointer(position,2,gl.FLOAT,false,0,0);
      const texture = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D,texture);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,true);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
      gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,img);
      gl.uniform1i(gl.getUniformLocation(program,'mark'),0);
      const assemblyUniform = gl.getUniformLocation(program,'assembly');
      const footprintUniform = gl.getUniformLocation(program,'footprint');
      // Sample the approved artwork once; particles return to its exact silhouette.
      const sample=document.createElement('canvas'); sample.width=96; sample.height=96;
      const sampleContext=sample.getContext('2d',{willReadFrequently:true});
      if(!sampleContext) throw new Error('Logo sampling unavailable');
      sampleContext.drawImage(img,0,0,96,96);
      const rgba=sampleContext.getImageData(0,0,96,96).data;
      const particles=[];
      for(let y=0;y<96;y+=2) for(let x=0;x<96;x++) {
        if(rgba[(y*96+x)*4+3]<180) continue;
        const seed=x*197+y*9277;
        const rand=n=>{const v=Math.sin(seed+n*71.7)*43758.5453;return v-Math.floor(v);};
        particles.push((x+.5)/48-1,1-(y+.5)/48,.18+rand(1)*.62,.2+rand(2)*.8,rand(3)*Math.PI*2);
      }
      const particleProgram=makeProgram(particleVertex,particleFragment);
      const particleBuffer=gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER,particleBuffer);
      gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(particles),gl.STATIC_DRAW);
      const home=gl.getAttribLocation(particleProgram,'home'), scatter=gl.getAttribLocation(particleProgram,'scatter');
      const particleAssembly=gl.getUniformLocation(particleProgram,'assembly');
      const particlePixels=gl.getUniformLocation(particleProgram,'pixels');
      const particlePointLimit=gl.getUniformLocation(particleProgram,'pointLimit');
      const particleTravel=gl.getUniformLocation(particleProgram,'travel');
      const smooth=value=>{const x=Math.max(0,Math.min(1,value));return x*x*(3-2*x);};
      const openingLogo=stage.closest('.hero')!==null;
      let entered=false, elapsed=0, previous=time, assembly=0;
      const render = seconds => {
        const dt=Math.max(0,Math.min(seconds-previous,.05)); previous=seconds;
        if(entered) elapsed+=dt;
        if(openingLogo && elapsed>=1.65) revealHero(true);
        const rect=stage.getBoundingClientRect();
        const entering=smooth((innerHeight-rect.top)/(rect.height*.9));
        const leaving=1.-smooth((64-rect.top)/(rect.height*.72));
        // Only the first page entrance is timed. After that, both directions
        // follow the same scroll position, including the lower logo's entrance.
        const entrance=openingLogo ? smooth(elapsed/2.35) : 1;
        const target=reduced.matches ? 1 : entrance*entering*leaving;
        assembly=target;
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.disable(gl.BLEND); gl.useProgram(program);
        gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
        gl.disableVertexAttribArray(home); gl.disableVertexAttribArray(scatter);
        gl.enableVertexAttribArray(position); gl.vertexAttribPointer(position,2,gl.FLOAT,false,0,0);
        gl.uniform1f(assemblyUniform,assembly);
        gl.uniform1f(footprintUniform,1.5/canvas.width);
        gl.drawArrays(gl.TRIANGLES,0,6);
        if(assembly<.999) {
          gl.useProgram(particleProgram); gl.bindBuffer(gl.ARRAY_BUFFER,particleBuffer);
          gl.disableVertexAttribArray(position);
          gl.enableVertexAttribArray(home); gl.vertexAttribPointer(home,2,gl.FLOAT,false,20,0);
          gl.enableVertexAttribArray(scatter); gl.vertexAttribPointer(scatter,3,gl.FLOAT,false,20,8);
          gl.uniform1f(particleAssembly,assembly); gl.uniform1f(particlePixels,canvas.width);
          gl.uniform1f(particlePointLimit,22*canvas.width/Math.min(800,Math.round(stage.clientWidth*1.5*Math.min(devicePixelRatio,2))));
          // Keep the local cloud moving after assembly reaches zero.
          const beyondExit=Math.max(0,(64-rect.top)/(rect.height*.72)-1);
          const beforeEntry=Math.max(0,(rect.top-innerHeight)/(rect.height*.9));
          gl.uniform1f(particleTravel,beyondExit-beforeEntry);
          gl.enable(gl.BLEND); gl.blendFunc(gl.ONE,gl.ONE_MINUS_SRC_ALPHA);
          gl.drawArrays(gl.POINTS,0,particles.length/5);
        }
      };
      const resize = () => {
        const size = Math.min(1560, gl.getParameter(gl.MAX_RENDERBUFFER_SIZE), Math.round(stage.clientWidth * 1.5 * Math.min(devicePixelRatio,3)));
        canvas.width = size; canvas.height = size; gl.viewport(0,0,size,size);
        render(reduced.matches ? 1.1 : time);
      };
      resize(); new ResizeObserver(resize).observe(stage);
      // The particle canvas extends beyond the logo stage. Observe its actual
      // bounds so the last visible stars never freeze when the stage exits.
      register(canvas, render, isVisible => {
        entered=isVisible; previous=time;
      });
      stage.classList.add('is-animated');
      canvas.addEventListener('webglcontextlost', () => {
        if(openingLogo) revealHero();
        stage.classList.remove('is-animated'); visible.delete(canvas); renderers.delete(canvas); visibilityHandlers.delete(canvas); visibility.unobserve(canvas); sync();
      });
    } catch {
      if(stage.closest('.hero')) revealHero();
      stage.classList.remove('is-animated');
    }
  }
  document.querySelectorAll('.logo-stage').forEach(stage => {
    const img = stage.querySelector('img');
    if (img.complete && img.naturalWidth) animateLogo(stage);
    else img.addEventListener('load', () => animateLogo(stage), {once:true});
    if(stage.closest('.hero')) img.addEventListener('error', () => revealHero(), {once:true});
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
