import App from './App.svelte';
import { mount } from 'svelte';
import './app.css';

// Generate noise texture via canvas
function createNoiseOverlay() {
  const size = 128;
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d')!;
  const imageData = ctx.createImageData(size, size);
  for (let i = 0; i < imageData.data.length; i += 4) {
    const v = Math.random() * 255;
    imageData.data[i] = v;
    imageData.data[i + 1] = v;
    imageData.data[i + 2] = v;
    imageData.data[i + 3] = 255;
  }
  ctx.putImageData(imageData, 0, 0);

  const el = document.createElement('div');
  el.id = 'noise-overlay';
  el.style.backgroundImage = `url(${canvas.toDataURL()})`;
  el.style.backgroundRepeat = 'repeat';
  document.body.appendChild(el);
}
createNoiseOverlay();

const app = mount(App, { target: document.getElementById('app')! });

export default app;
