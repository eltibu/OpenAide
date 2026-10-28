// The voice call avatar: a VRM model that breathes, blinks, looks at you,
// moves its mouth while it speaks and leans in while it listens. A model's
// own animations (.vrma) for idle, listening and speaking replace the
// built-in motion, and its gestures play once when the voice model asks.
//
// The app hands everything over through window.avatar (see voice_avatar.dart)
// and hears back on the AvatarBridge channel. Build with `npm run build`.
import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMUtils } from '@pixiv/three-vrm';
import {
  VRMAnimationLoaderPlugin,
  createVRMAnimationClip,
} from '@pixiv/three-vrm-animation';

const tell = (message) => {
  try {
    window.AvatarBridge?.postMessage(JSON.stringify(message));
  } catch (_) {}
};

const decode = (base64) => {
  const raw = atob(base64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes.buffer;
};

const canvas = document.getElementById('avatar');
let renderer, scene, camera, vrm, mixer;
let signals = { speaking: false, listening: false, level: 0, active: true };
const clips = {}; // state or gesture name -> AnimationClip
const actions = {};
let current = null; // the state action playing
let gesture = null;
let pending = [];
const animationData = {};

function resize() {
  if (!renderer) return;
  const w = canvas.clientWidth || window.innerWidth;
  const h = canvas.clientHeight || window.innerHeight;
  renderer.setSize(w, h, false);
  camera.aspect = w / Math.max(1, h);
  camera.updateProjectionMatrix();
}

async function loadClip(name, buffer) {
  const loader = new GLTFLoader();
  loader.register((parser) => new VRMAnimationLoaderPlugin(parser));
  const gltf = await loader.parseAsync(buffer, '');
  const animation = gltf.userData.vrmAnimations?.[0];
  if (!animation) throw new Error(`${name}: not a VRM animation`);
  clips[name] = createVRMAnimationClip(animation, vrm);
  actions[name] = mixer.clipAction(clips[name]);
}

// Built-in rest pose: arms down instead of the T-pose models come in.
function restPose(mirror) {
  const set = (name, x, y, z) =>
    vrm.humanoid.getNormalizedBoneNode(name)?.rotation.set(x * mirror, y, z * mirror);
  set('leftUpperArm', 0.02, -0.05, -1.3);
  set('rightUpperArm', 0.02, 0.05, 1.3);
  set('leftLowerArm', 0, -0.2, -0.04);
  set('rightLowerArm', 0, 0.2, 0.04);
  set('leftHand', 0, 0, -0.05);
  set('rightHand', 0, 0, 0.05);
}

window.avatar = {
  chunk(part) {
    pending.push(part);
  },

  async load() {
    try {
      const data = decode(pending.join(''));
      pending = [];
      const loader = new GLTFLoader();
      loader.register((parser) => new VRMLoaderPlugin(parser));
      const gltf = await loader.parseAsync(data, '');
      vrm = gltf.userData.vrm;
      if (!vrm) throw new Error('This file is not a VRM avatar.');
      VRMUtils.removeUnnecessaryVertices(gltf.scene);
      VRMUtils.rotateVRM0(vrm);

      scene = new THREE.Scene();
      scene.add(vrm.scene);
      scene.add(new THREE.HemisphereLight(0xffffff, 0x8b929f, 2));
      const sun = new THREE.DirectionalLight(0xffffff, 2.2);
      sun.position.set(-1, 2, 3);
      scene.add(sun);

      renderer = new THREE.WebGLRenderer({
        canvas,
        alpha: true,
        antialias: true,
        powerPreference: 'low-power',
      });
      renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
      renderer.setClearColor(0x000000, 0);
      renderer.outputColorSpace = THREE.SRGBColorSpace;

      const mirror = vrm.meta?.metaVersion === '0' ? -1 : 1;
      restPose(mirror);
      vrm.update(0);
      vrm.scene.updateMatrixWorld(true);

      // Head and shoulders, as on a video call.
      const head = vrm.humanoid.getNormalizedBoneNode('head');
      const headAt = head
        ? head.getWorldPosition(new THREE.Vector3())
        : new THREE.Box3().setFromObject(vrm.scene).getCenter(new THREE.Vector3());
      camera = new THREE.PerspectiveCamera(30, 1, 0.01, 100);
      camera.position.set(0, headAt.y - 0.08, headAt.z + 1.7);
      camera.lookAt(0, headAt.y - 0.2, headAt.z);
      const eyes = new THREE.Object3D();
      eyes.position.copy(camera.position);
      scene.add(eyes);
      if (vrm.lookAt) vrm.lookAt.target = eyes;

      mixer = new THREE.AnimationMixer(vrm.scene);
      mixer.addEventListener('finished', (e) => {
        if (gesture && e.action === gesture) {
          gesture.fadeOut(0.3);
          gesture = null;
          current?.reset().fadeIn(0.3).play();
          tell({ type: 'gesture-done' });
        }
      });
      for (const [name, buffer] of Object.entries(animationData)) {
        await loadClip(name, buffer).catch((e) => tell({ type: 'warning', message: `${e.message || e}` }));
      }

      resize();
      window.addEventListener('resize', resize);
      start(mirror);
      tell({ type: 'ready', gestures: Object.keys(clips).filter((n) => !n.startsWith('state:')) });
    } catch (e) {
      tell({ type: 'error', message: `${e?.message || e}` });
    }
  },

  // An animation for 'state:idle', 'state:listening', 'state:speaking', or a
  // gesture by name; sent before load().
  animation(name, base64) {
    animationData[name] = decode(base64);
  },

  signals(next) {
    signals = { ...signals, ...next };
  },

  gesture(name) {
    const action = actions[name];
    if (!action || !vrm) return 'unavailable';
    gesture?.stop();
    gesture = action;
    action.reset();
    action.setLoop(THREE.LoopOnce, 1);
    action.clampWhenFinished = true;
    current?.fadeOut(0.25);
    action.fadeIn(0.25).play();
    return 'started';
  },

  cancelGesture() {
    if (!gesture) return;
    gesture.fadeOut(0.25);
    gesture = null;
    current?.reset().fadeIn(0.25).play();
  },
};

function start(mirror) {
  let last = performance.now();
  const expressions = vrm.expressionManager;
  const has = (name) => !!expressions?.getExpression(name);
  const spine = vrm.humanoid.getNormalizedBoneNode('spine');
  const chest =
    vrm.humanoid.getNormalizedBoneNode('chest') ??
    vrm.humanoid.getNormalizedBoneNode('upperChest');
  const head = vrm.humanoid.getNormalizedBoneNode('head');
  let t = 0;
  let mouth = 0;
  let lean = 0;
  let nextBlink = 2.5;
  let blinkAt = -10;
  let state = '';

  const frame = () => {
    requestAnimationFrame(frame);
    if (document.hidden) return;
    const now = performance.now();
    const dt = Math.min((now - last) / 1000, 0.1);
    last = now;
    t += dt;

    // The state animation, when the model has one.
    const want = signals.speaking ? 'speaking' : signals.listening ? 'listening' : 'idle';
    if (want !== state) {
      state = want;
      const next = actions[`state:${want}`] ?? actions['state:idle'] ?? null;
      if (next !== current) {
        current?.fadeOut(0.4);
        current = next;
        if (current && !gesture) current.reset().fadeIn(0.4).play();
      }
    }
    const animated = !!current || !!gesture;
    if (!animated) {
      // Built-in motion: breathing, a lean while listening.
      restPose(mirror);
      lean += ((signals.listening ? 1 : 0) - lean) * Math.min(1, dt * 3);
      const breath = Math.sin(t * 1.7);
      if (spine) spine.rotation.set(0.02 + breath * 0.012 + lean * 0.04, 0, 0);
      if (chest) chest.rotation.set(breath * 0.01, 0, 0);
      if (head) {
        head.rotation.set(
          Math.sin(t * 0.6) * 0.02 + lean * 0.03,
          Math.sin(t * 0.37) * 0.04,
          lean * 0.06 * mirror,
        );
      }
    }
    mixer.update(dt);

    if (expressions) {
      // Mouth follows the voice.
      const target = signals.speaking ? Math.min(1, 0.15 + signals.level * 1.6) : 0;
      mouth += (target - mouth) * Math.min(1, dt * 18);
      if (has('aa')) expressions.setValue('aa', mouth * (0.7 + 0.3 * Math.sin(t * 22)));
      // Blinks every few seconds.
      if (t > nextBlink) {
        blinkAt = t;
        nextBlink = t + 2 + Math.random() * 3.5;
      }
      const b = t - blinkAt;
      const closed = b < 0.08 ? b / 0.08 : b < 0.18 ? 1 - (b - 0.08) / 0.1 : 0;
      if (has('blink')) expressions.setValue('blink', closed);
      else {
        if (has('blinkLeft')) expressions.setValue('blinkLeft', closed);
        if (has('blinkRight')) expressions.setValue('blinkRight', closed);
      }
    }
    vrm.update(dt);
    renderer.render(scene, camera);
  };
  frame();
}

tell({ type: 'page' });
