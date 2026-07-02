#!/usr/bin/env python3
"""Servidor local do editor de pixel art com gravacao direta na ROM.

Uso: make editor   (ou: python3 tools/arte-server.py)

Serve o tools/pixel-editor.html em http://127.0.0.1:2600 e expoe:

  POST /api/arte  recebe a matriz JSON do editor, gera as tabelas com
                  tools/arte-convert.py, substitui o bloco entre os
                  marcadores ARTE-TABELAS em src/screens.asm e roda
                  make. Resposta: {ok, avisos, make, rom}.
  POST /api/run   abre roms/testbr.bin no Stella (fecha a instancia
                  anterior, como o tools/snapshot.sh faz).

So aceita conexoes locais (127.0.0.1). Sem dependencias externas.
"""
import importlib.util
import json
import subprocess
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EDITOR = ROOT / 'tools' / 'pixel-editor.html'
SCREENS = ROOT / 'src' / 'screens.asm'
ROM = ROOT / 'roms' / 'testbr.bin'
STELLA = ROOT / 'tools' / 'stella' / 'Stella.app' / 'Contents' / 'MacOS' / 'Stella'
MARK_START = '; >>> ARTE-TABELAS'
MARK_END = '; <<< ARTE-TABELAS'
PORT = 2600

spec = importlib.util.spec_from_file_location(
    'arte_convert', ROOT / 'tools' / 'arte-convert.py')
arte_convert = importlib.util.module_from_spec(spec)
spec.loader.exec_module(arte_convert)


def update_rom(data):
    if data.get('largura') != 32 or data.get('altura') != 32:
        return {'ok': False, 'erro': 'a tela ARTE espera arte 32x32'}
    text, warnings, _ = arte_convert.convert(data['pixels'])
    source = SCREENS.read_text()
    start = source.find(MARK_START)
    end = source.find(MARK_END)
    if start < 0 or end < 0 or end < start:
        return {'ok': False,
                'erro': f'marcadores ARTE-TABELAS nao encontrados em {SCREENS}'}
    start = source.index('\n', start) + 1
    SCREENS.write_text(source[:start] + text + '\n' + source[end:])
    # -B: o make compara mtime com granularidade de 1 s e pularia o
    # rebuild quando duas gravacoes caem no mesmo segundo
    make = subprocess.run(['make', '-B'], cwd=ROOT,
                          capture_output=True, text=True)
    ok = make.returncode == 0
    return {
        'ok': ok,
        'avisos': warnings,
        'make': (make.stdout + make.stderr).strip().splitlines()[-4:],
        'rom': ROM.stat().st_size if ok and ROM.exists() else None,
    }


def open_stella():
    if not STELLA.exists():
        return {'ok': False, 'erro': f'Stella nao encontrado em {STELLA}'}
    subprocess.run(['pkill', '-x', 'Stella'], capture_output=True)
    subprocess.Popen([str(STELLA), str(ROM)], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {'ok': True}


class Handler(BaseHTTPRequestHandler):
    def _reply(self, body, ctype, status=200):
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, status=200):
        self._reply(json.dumps(obj).encode(), 'application/json', status)

    def do_GET(self):
        if self.path in ('/', '/index.html'):
            self._reply(EDITOR.read_bytes(), 'text/html; charset=utf-8')
        else:
            self._json({'ok': False, 'erro': 'rota desconhecida'}, 404)

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        if self.path == '/api/arte':
            try:
                data = json.loads(body)
            except ValueError:
                self._json({'ok': False, 'erro': 'JSON invalido'}, 400)
                return
            self._json(update_rom(data))
        elif self.path == '/api/run':
            self._json(open_stella())
        else:
            self._json({'ok': False, 'erro': 'rota desconhecida'}, 404)

    def log_message(self, fmt, *args):
        print(f'[arte-server] {fmt % args}')


def main():
    server = HTTPServer(('127.0.0.1', PORT), Handler)
    url = f'http://127.0.0.1:{PORT}/'
    print(f'editor de pixel art em {url} (Ctrl+C para sair)')
    if '--no-browser' not in sys.argv:
        threading.Timer(0.4, webbrowser.open, [url]).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
