import { Component, computed, inject, input, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { fechaHora } from '../core/formato';
import { Medicamento, Receta, RecetaItem, RecetasSolicitud, SugerenciaReceta } from '../core/modelos';

/** Fila editable de la receta. `base` es lo que propuso la base de conocimientos. */
interface Fila extends RecetaItem {
  advertencias: string | null;
  nota: string | null;
  base: Medicamento | null;
}

const normalizar = (t: string) => t.normalize('NFD').replace(/[̀-ͯ]/g, '').trim().toLowerCase();

/**
 * Receta del médico al revisar los resultados: a la izquierda los medicamentos (Rp.)
 * y a la derecha sus indicaciones y lo demás que el paciente debe seguir.
 * La base de conocimientos propone; el médico cambia lo que quiera y guarda SU receta.
 */
@Component({
  selector: 'app-receta',
  imports: [FormsModule],
  template: `
    <div class="card receta">
      <div class="entre">
        <div>
          <h2>Receta e indicaciones</h2>
          <small class="muted">
            @if (esMedico()) {
              Lo marcado <span class="sug">sugerido</span> viene de la base de conocimientos: es una propuesta y puede cambiarla o quitarla.
            } @else { Recetas emitidas por los médicos para esta solicitud. }
          </small>
        </div>
        @if (propia()) {
          <button class="secundario chico" (click)="pdf(propia()!.receta_id)">Receta (PDF)</button>
        }
      </div>
      @if (error()) { <div class="alerta error">{{ error() }}</div> }
      @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

      @if (esMedico()) {
        @if (sugerencia(); as sg) {
          @if (sg.medicamentos.length) {
            <div class="chips">
              <small class="muted">Sugeridos para {{ sg.diagnostico }}:</small>
              @for (m of sg.medicamentos; track m.medicamento_id) {
                <button type="button" class="chip" [disabled]="estaEnReceta(m)" (click)="agregar(m)"
                        [title]="m.nota ?? ''">+ {{ m.nombre }} {{ m.presentacion }}</button>
              }
            </div>
          } @else if (!sg.diagnosticos.length) {
            <small class="muted block">Las reglas no sugirieron diagnósticos para estos resultados: escriba la receta libremente.</small>
          }
        }
        <div class="campo"><label for="dx">Diagnóstico</label>
          <input id="dx" maxlength="500" [(ngModel)]="diagnostico" (ngModelChange)="dxSugerido.set(false)" placeholder="Diagnóstico para la receta" />
          @if (dxSugerido()) { <span class="sug">sugerido</span> }
        </div>

        <datalist id="vademecum">
          @for (m of vademecum(); track m.medicamento_id) { <option [value]="etiqueta(m)"></option> }
        </datalist>

        <div class="dos-col">
          <section>
            <h3>Rp. (receta)</h3>
            @for (f of filas(); track $index; let i = $index) {
              <div class="med">
                <div class="fila-med">
                  <strong>{{ i + 1 }}.</strong>
                  <input class="nombre" list="vademecum" maxlength="120" [(ngModel)]="f.nombre" (ngModelChange)="escribiendo(f)" (blur)="alSalir(f)"
                         placeholder="Escriba el medicamento…" aria-label="Medicamento" />
                  <button type="button" class="secundario chico" (click)="quitar(i)" title="Quitar">✕</button>
                </div>
                <small class="muted contador">{{ f.nombre.length }}/120 · medicamento, concentración y cantidad (ej. Ibuprofeno 600 mg, 20 tabletas)</small>
                @if (f.base) {
                  <small [class]="f.modificado ? 'muted' : 'sug'">{{ f.modificado ? 'modificado por el médico' : 'sugerido' }}</small>
                  @if (f.nota) { <small class="muted"> · {{ f.nota }}</small> }
                }
              </div>
            } @empty { <p class="muted">Sin medicamentos. Agregue uno o use las sugerencias.</p> }
            <button type="button" class="secundario chico" (click)="nueva()">+ Agregar medicamento</button>
          </section>

          <section>
            <h3>Indicaciones</h3>
            @for (f of filas(); track $index; let i = $index) {
              <div class="ind">
                <label>{{ i + 1 }}. {{ f.nombre || 'Medicamento' }}</label>
                <textarea rows="2" maxlength="1000" [(ngModel)]="f.indicaciones" (ngModelChange)="tocado(f)"
                          placeholder="Cómo tomarlo: dosis, cada cuánto, por cuántos días y recomendaciones"></textarea>
                <small class="muted">{{ (f.indicaciones ?? '').length }}/1000</small>
                @if (f.advertencias) { <small class="advertencia">⚠ {{ f.advertencias }}</small> }
              </div>
            }
            <div class="campo">
              <label for="gen">Además (dieta, controles, signos de alarma)
                @if (genSugerido()) { <span class="sug">sugerido</span> }</label>
              <textarea id="gen" rows="5" maxlength="2000" [(ngModel)]="generales" (ngModelChange)="genSugerido.set(false)"></textarea>
            </div>
          </section>
        </div>
        <div class="fila">
          <button (click)="guardar()" [disabled]="guardando() || !filas().length">{{ propia() ? 'Actualizar receta' : 'Guardar receta' }}</button>
          @if (propia(); as p) { <small class="muted">Guardada el {{ fechaHora(p.updated_at) }}</small> }
        </div>
      }

      @for (r of otras(); track r.receta_id) {
        <div class="dos-col leida">
          <section>
            <h3>Rp. · Dr(a). {{ r.medico }}</h3>
            @for (i of r.items; track i.receta_item_id) { <p><strong>{{ i.orden }}. {{ i.nombre }}</strong> {{ i.presentacion }}
              @if (i.cantidad) { <br /><small>Cantidad: {{ i.cantidad }}</small> }</p> }
          </section>
          <section>
            <h3>Indicaciones</h3>
            @for (i of r.items; track i.receta_item_id) {
              <p><strong>{{ i.orden }}. {{ i.nombre }}:</strong> {{ i.dosis }} {{ i.frecuencia }}{{ i.duracion_dias ? ' por ' + i.duracion_dias + ' días' : '' }}. {{ i.indicaciones }}</p>
            }
            @if (r.indicaciones_generales) { <p class="pre">{{ r.indicaciones_generales }}</p> }
            <button class="secundario chico" (click)="pdf(r.receta_id)">Receta (PDF)</button>
          </section>
        </div>
      } @empty {
        @if (!esMedico()) { <p class="muted">Todavía no hay recetas para esta solicitud.</p> }
      }
    </div>
  `,
  styles: `
    .receta { border-top: 3px solid var(--verde); }
    .dos-col { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 20px; margin: 12px 0; }
    .dos-col > section + section { border-left: 1px solid var(--borde); padding-left: 20px; }
    @media (max-width: 860px) { .dos-col { grid-template-columns: 1fr; } .dos-col > section + section { border-left: 0; padding-left: 0; } }
    .med { border-bottom: 1px dashed var(--borde); padding: 8px 0; }
    .fila-med { display: flex; gap: 8px; align-items: center; }
    .fila-med .nombre { flex: 1; font-weight: 600; }
    .mini { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
    .mini input { flex: 1 1 110px; min-width: 0; }
    .mini .dias { flex: 0 0 70px; } .mini .cant { flex: 0 1 110px; }
    .contador { display: block; margin-top: 2px; }
    .ind { margin-bottom: 10px; } .ind label { display: block; font-weight: 600; margin-bottom: 4px; }
    textarea { width: 100%; }
    .sug { background: var(--azul-suave); color: var(--azul); border-radius: 10px; padding: 1px 8px; font-size: 11px; font-weight: 600; }
    .advertencia { color: var(--ambar); display: block; margin-top: 2px; }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin: 10px 0; }
    .chip { background: var(--verde-suave); color: var(--verde-oscuro); border: 1px solid var(--verde); padding: 4px 10px; font-size: 12px; }
    .chip:disabled { opacity: .45; }
    .block { display: block; margin: 8px 0; }
    .leida { background: var(--fondo); border-radius: 6px; padding: 12px; }
    .pre { white-space: pre-line; }
  `,
})
export class RecetaPanel implements OnInit {
  readonly solicitudId = input.required<number>();
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly fechaHora = fechaHora;
  protected readonly esMedico = computed(() => this.auth.tiene('MEDICO'));

  protected readonly vademecum = signal<Medicamento[]>([]);
  protected readonly sugerencia = signal<SugerenciaReceta | null>(null);
  protected readonly propia = signal<Receta | null>(null);
  protected readonly recetas = signal<Receta[]>([]);
  protected readonly otras = computed(() => this.recetas().filter((r) => r.receta_id !== this.propia()?.receta_id));
  protected readonly filas = signal<Fila[]>([]);
  protected readonly dxSugerido = signal(false);
  protected readonly genSugerido = signal(false);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected readonly guardando = signal(false);
  protected diagnostico = '';
  protected generales = '';

  async ngOnInit() {
    try {
      const [datos, vademecum] = await Promise.all([
        this.api.get<RecetasSolicitud>(`/api/recetas/solicitud/${this.solicitudId()}`),
        this.esMedico() ? this.api.get<Medicamento[]>('/api/medicamentos') : Promise.resolve([]),
      ]);
      this.vademecum.set(vademecum);
      this.recetas.set(datos.recetas);
      this.sugerencia.set(datos.sugerencia ?? null);
      if (this.esMedico()) this.iniciar(datos.propia ?? null, datos.sugerencia ?? null);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  /** Con receta guardada se edita esa; si no, se parte de la propuesta de la base de conocimientos. */
  private iniciar(propia: Receta | null, sg: SugerenciaReceta | null) {
    this.propia.set(propia);
    if (propia) {
      this.diagnostico = propia.diagnostico ?? '';
      this.generales = propia.indicaciones_generales ?? '';
      this.filas.set(propia.items.map((i) => {
        const base = this.vademecum().find((m) => m.medicamento_id === i.medicamento_id) ?? null;
        return { ...i, base, advertencias: base?.advertencias ?? null, nota: null };
      }));
      return;
    }
    if (sg) {
      this.diagnostico = sg.diagnostico;
      this.generales = sg.indicaciones_generales;
      this.dxSugerido.set(!!sg.diagnostico);
      this.genSugerido.set(!!sg.indicaciones_generales);
      this.filas.set(sg.medicamentos.map((m) => this.desdeBase(m)));
    }
  }

  protected etiqueta(m: Medicamento): string {
    return `${m.nombre} · ${m.presentacion}`;
  }

  /** "1 tableta (500 mg) cada 12 horas por 90 días. Tomar con el desayuno…" */
  private comoTomar(m: Medicamento): string {
    const dias = m.duracion_dias ? ` por ${m.duracion_dias} días` : '';
    return `${m.dosis} ${m.frecuencia}${dias}. ${m.indicaciones}`.slice(0, 1000);
  }

  private desdeBase(m: Medicamento): Fila {
    return {
      medicamento_id: m.medicamento_id, nombre: `${m.nombre} ${m.presentacion}`.slice(0, 120), presentacion: null, via: null,
      dosis: '', frecuencia: '', duracion_dias: null, cantidad: null, indicaciones: this.comoTomar(m),
      modificado: false, base: m, advertencias: m.advertencias, nota: m.nota ?? null,
    };
  }

  /** Busca en el vademécum lo que se va escribiendo: etiqueta exacta, nombre exacto o un único nombre que empiece así. */
  private buscar(texto: string): Medicamento | null {
    const t = normalizar(texto);
    if (t.length < 3) return null;
    const lista = this.vademecum();
    const exacto = lista.find((m) => normalizar(this.etiqueta(m)) === t || normalizar(m.nombre) === t);
    if (exacto) return exacto;
    const empiezan = lista.filter((m) => normalizar(m.nombre).startsWith(t));
    return empiezan.length === 1 ? empiezan[0] : null;
  }

  /** Al escribir el nombre se completan solas la dosis y las indicaciones (si el médico aún no las cambió). */
  protected escribiendo(f: Fila) {
    const m = this.buscar(f.nombre);
    if (m && (!f.base || f.base.medicamento_id !== m.medicamento_id) && !f.modificado) {
      // Si eligió de la lista, queda "Nombre presentación"; si va escribiendo, se respeta lo que escribe.
      const nombre = normalizar(this.etiqueta(m)) === normalizar(f.nombre) ? `${m.nombre} ${m.presentacion}` : f.nombre;
      Object.assign(f, this.desdeBase(m), { nombre, nota: f.nota });
    } else if (!m && f.base && !normalizar(f.nombre).startsWith(normalizar(f.base.nombre))
               && !normalizar(f.base.nombre).startsWith(normalizar(f.nombre))) {
      // Escribió otro medicamento que no está en la base: deja de estar vinculado.
      f.medicamento_id = null;
      f.base = null;
      f.advertencias = null;
    }
    this.filas.update((x) => [...x]);
  }

  protected alSalir(f: Fila) {
    // Al salir del campo, un nombre a medio escribir se completa con el del vademécum y su presentación.
    if (f.base && normalizar(f.base.nombre).startsWith(normalizar(f.nombre))) f.nombre = `${f.base.nombre} ${f.base.presentacion}`;
  }

  protected tocado(f: Fila) {
    if (f.base) f.modificado = true;
  }

  protected estaEnReceta(m: Medicamento): boolean {
    return this.filas().some((f) => f.medicamento_id === m.medicamento_id);
  }

  protected agregar(m: Medicamento) {
    this.filas.update((x) => [...x, this.desdeBase(m)]);
  }

  protected nueva() {
    this.filas.update((x) => [...x, {
      medicamento_id: null, nombre: '', presentacion: null, via: 'Oral', dosis: '', frecuencia: '', duracion_dias: null,
      cantidad: null, indicaciones: null, modificado: false, base: null, advertencias: null, nota: null,
    }]);
  }

  protected quitar(i: number) {
    this.filas.update((x) => x.filter((_, j) => j !== i));
  }

  async guardar() {
    this.error.set('');
    this.aviso.set('');
    const incompleta = this.filas().findIndex((f) => !f.nombre?.trim());
    if (incompleta >= 0) {
      this.error.set(`Escriba el nombre del medicamento ${incompleta + 1}.`);
      return;
    }
    this.guardando.set(true);
    try {
      const r = await this.api.put<Receta>(`/api/recetas/solicitud/${this.solicitudId()}`, {
        diagnostico: this.diagnostico || null,
        indicaciones_generales: this.generales || null,
        items: this.filas().map((f) => ({
          medicamento_id: f.medicamento_id, nombre: f.nombre, presentacion: f.presentacion, via: f.via, dosis: f.dosis,
          frecuencia: f.frecuencia, duracion_dias: f.duracion_dias ? Number(f.duracion_dias) : null, cantidad: f.cantidad,
          indicaciones: f.indicaciones, modificado: f.modificado,
        })),
      });
      this.recetas.update((x) => [...x.filter((y) => y.receta_id !== r.receta_id), r]);
      this.propia.set(r);
      this.dxSugerido.set(false);
      this.genSugerido.set(false);
      this.aviso.set('Receta guardada. El paciente la ve en su portal.');
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.guardando.set(false);
    }
  }

  async pdf(recetaId: number) {
    try {
      await this.api.abrirArchivo(`/api/recetas/${recetaId}/pdf`);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
