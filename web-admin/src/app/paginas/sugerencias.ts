import { Component, inject, input, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, fechaHora, hoyIso, textoEstado } from '../core/formato';
import { GuiaClinica, Sugerencia } from '../core/modelos';

/**
 * Sugerencias de diagnóstico de la base de conocimientos para una solicitud.
 * El médico acepta (y registra el tratamiento con el protocolo propuesto) o
 * descarta con un motivo. El sistema sugiere; el médico decide.
 */
@Component({
  selector: 'app-sugerencias',
  imports: [FormsModule],
  template: `
    <div class="card panel">
      <div class="entre">
        <div>
          <h2>Sugerencias de diagnóstico</h2>
          <small class="muted">Base de conocimientos por reglas. Son sugerencias: la decisión es del médico tratante.</small>
        </div>
        <button class="secundario chico" (click)="evaluar()" [disabled]="cargando()">Volver a evaluar</button>
      </div>
      @if (error()) { <div class="alerta error">{{ error() }}</div> }
      @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

      @for (s of lista(); track s.sugerencia_id) {
        <div class="sug" [class.hecha]="s.estado !== 'PENDIENTE'">
          <div class="entre">
            <div>
              <strong>{{ s.codigo_cie10 }} · {{ s.diagnostico }}</strong>
              <span [class]="'badge ' + colorConfianza(s.confianza)">confianza {{ s.confianza.toLowerCase() }}</span>
            </div>
            <span [class]="claseSugerencia(s.estado)">{{ textoEstado(s.estado) }}</span>
          </div>
          <div class="por-que">Por qué: {{ s.explicacion }}</div>
          <div>Recomendación: {{ s.recomendacion }}</div>
          <small class="muted">{{ s.fuente }}
            @if (s.guia_clave) { · <a href="#" (click)="verGuia(s.guia_clave); $event.preventDefault()">Ver guía clínica</a> }
          </small>

          @if (s.estado !== 'PENDIENTE') {
            <small class="muted block">{{ s.estado === 'ACEPTADA' ? 'Aceptada' : 'Descartada' }} por {{ s.respondida_por }}
              el {{ fechaHora(s.respondida_at) }}{{ s.motivo ? ' · ' + s.motivo : '' }}{{ s.tratamiento_id ? ' · tratamiento #' + s.tratamiento_id : '' }}</small>
          } @else if (auth.tiene('MEDICO')) {
            @if (abierta() === s.sugerencia_id) {
              <form class="tratamiento" (ngSubmit)="aceptar(s)">
                <h3>Registrar tratamiento</h3>
                <div class="campo"><label>Diagnóstico</label><input name="d" [(ngModel)]="t.diagnostico" required /></div>
                <div class="campo"><label>Indicaciones (protocolo sugerido, editable)</label>
                  <textarea name="i" [(ngModel)]="t.indicaciones" required></textarea></div>
                <div class="fila">
                  <div class="campo"><label>Inicio</label><input type="date" name="fi" [(ngModel)]="t.fecha_inicio" required /></div>
                  <div class="campo"><label>Fin</label><input type="date" name="ff" [(ngModel)]="t.fecha_fin" /></div>
                </div>
                <div class="fila">
                  <button type="submit" [disabled]="!t.diagnostico || !t.indicaciones">Aceptar y registrar tratamiento</button>
                  <button type="button" class="secundario" (click)="aceptarSinTratamiento(s)">Aceptar sin tratamiento</button>
                  <button type="button" class="secundario" (click)="abierta.set(null)">Cancelar</button>
                </div>
              </form>
            } @else {
              <div class="fila acciones">
                <button class="chico" (click)="abrir(s)">Aceptar</button>
                <button class="secundario chico" (click)="descartar(s)">Descartar</button>
              </div>
            }
          }
        </div>
      } @empty {
        <p class="muted">{{ cargando() ? 'Evaluando…' : 'Ninguna regla de la base de conocimientos se cumple con los resultados de esta solicitud.' }}</p>
      }
    </div>

    @if (guia(); as g) {
      <div class="velo" (click)="guia.set(null)">
        <div class="card modal" (click)="$event.stopPropagation()">
          <div class="entre"><h2>{{ g.titulo }}</h2><button class="secundario chico" (click)="guia.set(null)">Cerrar</button></div>
          <small class="muted">{{ g.fuente }} · Diagnósticos: {{ g.diagnosticos.join(', ') }}</small>
          <table>
            <thead><tr><th>Parámetro</th><th>Rango</th><th>Interpretación</th></tr></thead>
            <tbody>@for (c of g.criterios; track $index) { <tr><td>{{ c.parametro }}</td><td>{{ c.rango }}</td><td>{{ c.interpretacion }}</td></tr> }</tbody>
          </table>
          @for (sec of g.secciones; track sec.titulo) { <h3>{{ sec.titulo }}</h3><p>{{ sec.texto }}</p> }
          <small class="muted">Resumen académico con valores referenciales; no sustituye el criterio médico.</small>
        </div>
      </div>
    }
  `,
  styles: `
    .panel h2 { margin-bottom: 2px; }
    .sug { border-left: 4px solid var(--azul); background: #fafcfe; border-radius: 6px; padding: 10px 14px; margin-top: 12px; }
    .sug.hecha { border-left-color: var(--borde); opacity: .85; }
    .sug .badge { margin-left: 8px; }
    .por-que { margin: 6px 0 2px; color: var(--azul); font-weight: 600; }
    .block { display: block; margin-top: 4px; }
    .acciones { margin-top: 8px; }
    .tratamiento { margin-top: 10px; border-top: 1px dashed var(--borde); padding-top: 10px; }
    .velo { position: fixed; inset: 0; background: rgb(0 0 0 / 35%); display: grid; place-items: center; padding: 16px; z-index: 10; }
    .modal { width: min(720px, 100%); max-height: 85vh; overflow-y: auto; }
  `,
})
export class Sugerencias implements OnInit {
  readonly solicitudId = input.required<number>();
  readonly pacienteId = input.required<number>();
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly textoEstado = textoEstado;
  protected readonly fechaHora = fechaHora;
  protected readonly lista = signal<Sugerencia[]>([]);
  protected readonly cargando = signal(false);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected readonly abierta = signal<number | null>(null);
  protected readonly guia = signal<GuiaClinica | null>(null);
  protected t = { diagnostico: '', indicaciones: '', fecha_inicio: hoyIso(), fecha_fin: '' };

  ngOnInit() {
    this.cargar();
  }

  protected colorConfianza(c: string) {
    return c === 'ALTA' ? 'rojo' : c === 'MEDIA' ? 'ambar' : 'gris';
  }

  protected claseSugerencia(estado: string) {
    return estado === 'PENDIENTE' ? 'badge azul' : claseEstado(estado === 'ACEPTADA' ? 'APROBADO' : 'CANCELADA');
  }

  async cargar() {
    try {
      this.lista.set(await this.api.get<Sugerencia[]>('/api/conocimiento/sugerencias', { solicitud_id: this.solicitudId() }));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async evaluar() {
    this.cargando.set(true);
    this.limpiar();
    try {
      const r = await this.api.post<{ nuevas: number; sugerencias: Sugerencia[] }>(`/api/conocimiento/evaluar/${this.solicitudId()}`);
      this.lista.set(r.sugerencias);
      this.aviso.set(r.nuevas ? `${r.nuevas} sugerencia(s) nueva(s).` : 'No hay sugerencias nuevas.');
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.cargando.set(false);
    }
  }

  abrir(s: Sugerencia) {
    const fin = s.duracion_dias ? new Date(Date.now() + s.duracion_dias * 86_400_000).toISOString().slice(0, 10) : '';
    this.t = {
      diagnostico: `${s.codigo_cie10} - ${s.diagnostico}`,
      indicaciones: s.protocolo ?? s.recomendacion,
      fecha_inicio: hoyIso(),
      fecha_fin: fin,
    };
    this.abierta.set(s.sugerencia_id);
  }

  async aceptar(s: Sugerencia) {
    this.limpiar();
    try {
      const trat = await this.api.post<{ tratamiento_id: number }>('/api/tratamientos', {
        paciente_id: this.pacienteId(), solicitud_id: this.solicitudId(), diagnostico: this.t.diagnostico,
        indicaciones: this.t.indicaciones, fecha_inicio: this.t.fecha_inicio, fecha_fin: this.t.fecha_fin || null,
      });
      await this.responder(s, true, null, trat.tratamiento_id, 'Sugerencia aceptada y tratamiento registrado.');
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async aceptarSinTratamiento(s: Sugerencia) {
    this.limpiar();
    await this.responder(s, true, null, null, 'Sugerencia aceptada.');
  }

  async descartar(s: Sugerencia) {
    const motivo = prompt(`¿Por qué descarta "${s.diagnostico}"? (queda registrado para medir la precisión de la regla)`);
    if (!motivo?.trim()) return;
    this.limpiar();
    await this.responder(s, false, motivo.trim(), null, 'Sugerencia descartada.');
  }

  async verGuia(clave: string) {
    try {
      this.guia.set(await this.api.get<GuiaClinica>(`/api/conocimiento/guias/${clave}`));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  private async responder(s: Sugerencia, aceptar: boolean, motivo: string | null, tratamiento_id: number | null, exito: string) {
    try {
      await this.api.post(`/api/conocimiento/sugerencias/${s.sugerencia_id}/responder`, { aceptar, motivo, tratamiento_id });
      this.abierta.set(null);
      this.aviso.set(exito);
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  private limpiar() {
    this.error.set('');
    this.aviso.set('');
  }
}
