import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

const config = {
  preprocess: vitePreprocess(),
  kit: {
    paths: { base: process.env.BASE_PATH ?? '' },
    adapter: adapter({ fallback: '404.html', precompress: false, strict: true }),
    prerender: {
      handleHttpError: 'fail',
      handleMissingId: 'fail'
    }
  },
  dynamicCompileOptions({ filename }) {
    if (!filename.split(/[/\\]/).includes('node_modules')) {
      return { runes: true };
    }
  }
};

export default config;
