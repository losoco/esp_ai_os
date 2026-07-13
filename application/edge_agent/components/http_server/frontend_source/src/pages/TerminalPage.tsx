import { Eraser, SendHorizontal } from 'lucide-solid';
import {
  createSignal,
  onCleanup,
  onMount,
  Show,
  type Component,
} from 'solid-js';
import { TabShell } from '../components/layout/TabShell';
import { PageHeader } from '../components/ui/PageHeader';
import { Button } from '../components/ui/Button';
import { t } from '../i18n';

const MAX_OUTPUT_LEN = 65536;
const RECONNECT_DELAY_MS = 3000;

export const TerminalPage: Component = () => {
  const [output, setOutput] = createSignal('');
  const [input, setInput] = createSignal('');
  const [connected, setConnected] = createSignal(false);
  let ws: WebSocket | null = null;
  let preRef: HTMLPreElement | undefined;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let shouldReconnect = false;

  const scrollToBottom = () => {
    if (preRef) {
      preRef.scrollTop = preRef.scrollHeight;
    }
  };

  const connect = () => {
    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = `${proto}//${window.location.host}/ws/terminal`;
    try {
      ws = new WebSocket(url);
    } catch {
      scheduleReconnect();
      return;
    }

    ws.onopen = () => {
      setConnected(true);
    };

    ws.onmessage = (e) => {
      setOutput((prev) => {
        let next = prev + e.data;
        if (next.length > MAX_OUTPUT_LEN) {
          next = next.slice(-MAX_OUTPUT_LEN);
        }
        return next;
      });
      requestAnimationFrame(scrollToBottom);
    };

    ws.onclose = () => {
      setConnected(false);
      if (shouldReconnect) {
        scheduleReconnect();
      }
    };

    ws.onerror = () => {
      ws?.close();
    };
  };

  const scheduleReconnect = () => {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
    }
    reconnectTimer = setTimeout(() => {
      if (shouldReconnect) {
        connect();
      }
    }, RECONNECT_DELAY_MS);
  };

  const disconnect = () => {
    shouldReconnect = false;
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    if (ws) {
      ws.onclose = null;
      ws.close();
      ws = null;
    }
    setConnected(false);
  };

  const sendCommand = () => {
    const cmd = input().trim();
    if (!cmd || !ws || ws.readyState !== WebSocket.OPEN) {
      return;
    }
    ws.send(cmd);
    setInput('');
  };

  const clearOutput = () => {
    setOutput('');
  };

  onMount(() => {
    shouldReconnect = true;
    connect();
  });

  onCleanup(() => {
    disconnect();
  });

  return (
    <TabShell>
      <PageHeader
        title={t('navTerminal') as string}
        description={t('terminalDesc') as string}
        actions={
          <div class="flex items-center gap-2">
            <Show
              when={connected()}
              fallback={
                <span class="flex items-center gap-1.5 text-xs text-[var(--color-text-muted)]">
                  <span class="h-2 w-2 rounded-full bg-red-500" />
                  {t('terminalDisconnected') as string}
                </span>
              }
            >
              <span class="flex items-center gap-1.5 text-xs text-[var(--color-text-muted)]">
                <span class="h-2 w-2 rounded-full bg-green-500" />
                {t('terminalConnected') as string}
              </span>
            </Show>
            <Button size="sm" variant="secondary" onClick={clearOutput}>
              <Eraser class="mr-1 h-3.5 w-3.5" />
              {t('terminalClear') as string}
            </Button>
          </div>
        }
      />

      <div class="flex h-[calc(100vh-220px)] min-h-[300px] flex-col">
        <pre
          ref={preRef}
          class="flex-1 overflow-auto rounded-[var(--radius-md)] border border-white/10 bg-black p-3 font-mono text-xs leading-relaxed text-green-400"
        >
          {output() || t('terminalEmpty') as string}
        </pre>

        <div class="mt-2 flex gap-2">
          <input
            value={input()}
            onInput={(e) => setInput(e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                sendCommand();
              }
            }}
            placeholder={t('terminalInputPlaceholder') as string}
            class="flex-1 rounded-[var(--radius-sm)] border border-white/10 bg-zinc-900 px-3 py-2 font-mono text-xs text-white placeholder:text-zinc-500 focus:border-white/20 focus:outline-none"
            disabled={!connected()}
            autocomplete="off"
            spellcheck={false}
          />
          <Button
            size="sm"
            onClick={sendCommand}
            disabled={!connected() || !input().trim()}
          >
            <SendHorizontal class="mr-1 h-3.5 w-3.5" />
            {t('terminalSend') as string}
          </Button>
        </div>
      </div>
    </TabShell>
  );
};
