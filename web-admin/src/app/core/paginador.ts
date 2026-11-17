import { Component, input, output } from '@angular/core';

/** Respuesta paginada de la API (listados con ?pagina=N&por_pagina=M). */
export interface Pagina<T> {
  items: T[];
  total: number;
  pagina: number;
  por_pagina: number;
  paginas: number;
}

export const POR_PAGINA = 10;

export function paginaVacia<T>(): Pagina<T> {
  return { items: [], total: 0, pagina: 1, por_pagina: POR_PAGINA, paginas: 1 };
}

/**
 * Pagina en el navegador una lista que ya está cargada (catálogo, reglas, agenda…),
 * filtrándola antes por el texto buscado.
 */
export function paginarLocal<T>(lista: T[], pagina: number, q = '', texto: (x: T) => string = (x) => JSON.stringify(x)): Pagina<T> {
  const buscado = q.trim().toLowerCase();
  const filtrados = buscado ? lista.filter((x) => texto(x).toLowerCase().includes(buscado)) : lista;
  const paginas = Math.max(1, Math.ceil(filtrados.length / POR_PAGINA));
  const actual = Math.min(Math.max(1, pagina), paginas);
  return {
    items: filtrados.slice((actual - 1) * POR_PAGINA, actual * POR_PAGINA),
    total: filtrados.length, pagina: actual, por_pagina: POR_PAGINA, paginas,
  };
}

/** Controles "Anterior / Siguiente" con el resumen "21–40 de 135". */
@Component({
  selector: 'app-paginador',
  template: `
    @let p = pagina();
    <div class="paginador">
      <small class="muted">
        @if (p.total) { {{ (p.pagina - 1) * p.por_pagina + 1 }}–{{ desde(p) }} de {{ p.total }} } @else { Sin registros }
      </small>
      <div class="fila">
        <button type="button" class="secundario chico" [disabled]="p.pagina <= 1" (click)="cambiar.emit(p.pagina - 1)">← Anterior</button>
        <small>Página {{ p.pagina }} de {{ p.paginas }}</small>
        <button type="button" class="secundario chico" [disabled]="p.pagina >= p.paginas" (click)="cambiar.emit(p.pagina + 1)">Siguiente →</button>
      </div>
    </div>
  `,
  styles: `
    .paginador { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; margin-top: 12px; }
    .paginador .fila { align-items: center; }
  `,
})
export class Paginador {
  readonly pagina = input.required<Pagina<unknown>>();
  readonly cambiar = output<number>();

  protected desde(p: Pagina<unknown>): number {
    return Math.min(p.pagina * p.por_pagina, p.total);
  }
}
