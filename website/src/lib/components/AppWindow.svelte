<script lang="ts">
  import Screenshot from './Screenshot.svelte';

  let {
    name = '01-host-detail',
    alt = 'SSH Config Manager app',
    class: className = ''
  }: { name?: string; alt?: string; class?: string } = $props();
</script>

<Screenshot {name} {alt} class="app-frame {className}" />
