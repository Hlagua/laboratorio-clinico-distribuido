import { Component, inject, input, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, dinero, fechaHora, rango, textoEstado } from '../core/formato';
import { ExamenSolicitado, Parametro, Solicitud, TipoExamen } from '../core/modelos';

/** Valor que el laboratorista escribe por parámetro (número o texto cualitativo). */
interface Captura { parametro: Parametro; valor: string }

@Component({
  selector: 'app-solicitud-detalle',
  imports: [FormsModule, RouterLink],
  template: `
    <a routerLink="/solicitudes">← Volver a solicitudes</a>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    @if (s(); as s) {
      <div class="entre cabeza">
        <div>
          <h1>{{ s.codigo }} <span [class]="claseEstado(s.estado)">{{ textoEstado(s.estado) }}</span></h1>
          <p class="sub">{{ s.paciente }} · CI {{ s.cedula }} · {{ fechaHora(s.created_at) }}
            @if (s.medico_id) { · Ordenado por {{ s.medico }} } · Total {{ dinero(s.total) }}</p>
        </div>
        @if (tieneResultados()) {
          <button class="secundario" (click)="pdf()">Descargar PDF</button>
        }
      </div>
      @if (s.estado === 'REGISTRADA') {
        <div class="alerta aviso">La solicitud aún no está pagada: no se pueden registrar muestras ni resultados.</div>
      }

      @for (ex of s.examenes; track ex.detalle_id) {
        <div class="card">
          <div class="entre">
            <h2>{{ ex.examen }} <small class="muted">{{ ex.codigo }}</small></h2>
            <span [class]="claseEstado(ex.estado)">{{ textoEstado(ex.estado) }}</span>
          </div>

          @if (ex.resultado_id) {
            <div class="tabla-scroll">
              <table>
                <thead><tr><th>Parámetro</th><th class="num">Resultado</th><th>Unidad</th><th>Referencia</th></tr></thead>
                <tbody>
                  @for (v of ex.valores; track v.parametro_id) {
                    <tr>
                      <td>{{ v.parametro }}</td>
                      <td class="num" [class.fuera]="v.fuera_rango">{{ v.valor_texto ?? v.valor_numerico }}{{ v.fuera_rango ? ' ⚠' : '' }}</td>
                      <td>{{ v.unidad }}</td><td>{{ rango(v.valor_ref_min, v.valor_ref_max, v.valor_ref_texto) }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            </div>
            <p class="muted">Registrado por {{ ex.laboratorista }} el {{ fechaHora(ex.fecha_resultado) }}.
              @if (ex.observaciones_laboratorio) { Nota: {{ ex.observaciones_laboratorio }} }</p>
            @for (o of ex.observaciones_medicas; track o.observacion_id) {
              <div class="obs"><strong>{{ o.medico }}</strong> <small class="muted">{{ fechaHora(o.created_at) }}</small><br />{{ o.texto }}</div>
            }
            @if (auth.tiene('MEDICO')) {
              <form class="fila" (ngSubmit)="observar(ex)">
                <div class="campo"><label>Nueva observación médica</label>
                  <textarea [name]="'obs' + ex.detalle_id" [(ngModel)]="observacion[ex.detalle_id]"></textarea></div>
                <div class="campo"><button type="submit" [disabled]="!observacion[ex.detalle_id]?.trim()">Guardar observación</button></div>
              </form>
            }
          } @else if (auth.tiene('LABORATORISTA') && puedeProcesar()) {
            @if (ex.estado === 'PENDIENTE') {
              <p class="muted">Primero registre la toma de muestra.</p>
              <button class="secundario" (click)="muestra(ex)">Registrar toma de muestra</button>
            } @else if (capturas[ex.detalle_id]) {
              <form (ngSubmit)="guardarResultado(ex)">
                <div class="tabla-scroll">
                  <table>
                    <thead><tr><th>Parámetro</th><th>Valor</th><th>Unidad</th><th>Referencia</th></tr></thead>
                    <tbody>
                      @for (c of capturas[ex.detalle_id]; track c.parametro.parametro_id) {
                        <tr>
                          <td>{{ c.parametro.nombre }}</td>
                          <td><input [name]="'v' + c.parametro.parametro_id" [(ngModel)]="c.valor" required
                                     [placeholder]="c.parametro.valor_ref_texto ? 'texto' : 'número'" /></td>
                          <td>{{ c.parametro.unidad }}</td>
                          <td>{{ rango(c.parametro.valor_ref_min, c.parametro.valor_ref_max, c.parametro.valor_ref_texto) }}</td>
                        </tr>
                      }
                    </tbody>
                  </table>
                </div>
                <div class="campo"><label>Observaciones del laboratorio</label>
                  <textarea [name]="'nota' + ex.detalle_id" [(ngModel)]="notas[ex.detalle_id]"></textarea></div>
                <button type="submit" [disabled]="guardando()">Guardar resultado</button>
              </form>
            }
          } @else {
            <p class="muted">Resultado pendiente.</p>
          }
        </div>
      }
    } @else if (!error()) {
      <p class="muted">Cargando…</p>
    }
  `,
  styles: `
    .cabeza { margin-top: 12px; }
    h1 .badge { vertical-align: middle; margin-left: 8px; }
    .obs { background: var(--azul-suave); border-radius: 6px; padding: 8px 12px; margin: 8px 0; }
  `,
})
export class SolicitudDetalle implements OnInit {
  readonly id = input.required<string>();
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly fechaHora = fechaHora;
  protected readonly dinero = dinero;
  protected readonly rango = rango;
  protected readonly s = signal<Solicitud | null>(null);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected readonly guardando = signal(false);
  protected capturas: Record<number, Captura[]> = {};
  protected notas: Record<number, string> = {};
  protected observacion: Record<number, string> = {};
  private catalogo: TipoExamen[] = [];

  async ngOnInit() {
    try {
      this.catalogo = await this.api.get<TipoExamen[]>('/api/examenes/catalogo');
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  private async cargar() {
    const s = await this.api.get<Solicitud>(`/api/solicitudes/${this.id()}`);
    for (const ex of s.examenes) {
      if (!ex.resultado_id && !this.capturas[ex.detalle_id]) {
        const tipo = this.catalogo.find((t) => t.tipo_examen_id === ex.tipo_examen_id);
        this.capturas[ex.detalle_id] = (tipo?.parametros ?? []).map((p) => ({ parametro: p, valor: '' }));
      }
    }
    this.s.set(s);
  }

  protected puedeProcesar(): boolean {
    return ['PAGADA', 'EN_PROCESO'].includes(this.s()?.estado ?? '');
  }

  protected tieneResultados(): boolean {
    return !!this.s()?.examenes.some((e) => e.resultado_id);
  }

  async muestra(ex: ExamenSolicitado) {
    await this.accion(() => this.api.post(`/api/solicitudes/detalle/${ex.detalle_id}/muestra`), 'Toma de muestra registrada.');
  }

  async guardarResultado(ex: ExamenSolicitado) {
    const valores = (this.capturas[ex.detalle_id] ?? []).map((c) => {
      const num = Number(c.valor.replace(',', '.'));
      return c.parametro.valor_ref_texto || Number.isNaN(num)
        ? { parametro_id: c.parametro.parametro_id, texto: c.valor.trim() }
        : { parametro_id: c.parametro.parametro_id, valor: num };
    });
    this.guardando.set(true);
    await this.accion(() => this.api.post('/api/resultados', {
      detalle_id: ex.detalle_id, valores, observaciones: this.notas[ex.detalle_id] || null,
    }), `Resultado de ${ex.examen} registrado.`);
    this.guardando.set(false);
  }

  async observar(ex: ExamenSolicitado) {
    await this.accion(() => this.api.post('/api/observaciones', {
      resultado_id: ex.resultado_id, texto: this.observacion[ex.detalle_id].trim(),
    }), 'Observación registrada.');
    this.observacion[ex.detalle_id] = '';
  }

  async pdf() {
    try {
      await this.api.abrirArchivo(`/api/solicitudes/${this.id()}/pdf`);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  private async accion(fn: () => Promise<unknown>, exito: string) {
    this.error.set('');
    this.aviso.set('');
    try {
      await fn();
      this.aviso.set(exito);
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
