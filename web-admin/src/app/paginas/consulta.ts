import { Component, computed, inject, input, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, dinero, fechaHora, hora, hoyIso, textoEstado } from '../core/formato';
import { Cita, Franja, Laboratorio, Paciente, SolicitudResumen, TipoExamen, Tratamiento } from '../core/modelos';
import { RecetaPanel } from './receta';

interface Nota { motivo: string | null; sintomas: string | null; examen_fisico: string | null; diagnostico: string | null; updated_at: string | null }

/**
 * Consulta médica: el médico anota el motivo, las molestias y el diagnóstico; receta (aunque no ordene exámenes,
 * por ejemplo en una gripe), ordena exámenes si hacen falta y agenda el control (que también se cobra).
 * Ve primero los exámenes de esta consulta y, si los necesita, los anteriores.
 */
@Component({
  selector: 'app-consulta',
  imports: [FormsModule, RecetaPanel],
  template: `
    <button type="button" class="secundario chico" (click)="volver()">&larr; Mis consultas</button>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    @if (cita(); as c) {
      <div class="entre cabeza">
        <div>
          <h1>{{ c.origen === 'MEDICO' ? 'Control' : 'Consulta' }}: {{ c.paciente }}
            <span [class]="claseEstado(c.estado)">{{ textoEstado(c.estado) }}</span></h1>
          <p class="sub">{{ c.fecha }} · {{ hora(c.hora_inicio) }} · CI {{ c.cedula }}</p>
        </div>
        @if (c.estado === 'CONFIRMADA') {
          <button (click)="finalizar()">Finalizar consulta</button>
        }
      </div>
      @if (c.estado === 'PENDIENTE_PAGO') {
        <div class="alerta aviso">El paciente aún no paga {{ c.origen === 'MEDICO' ? 'el control' : 'la consulta' }}. Puede revisar
          su historial, pero la receta y el cierre quedan disponibles cuando esté pagada.</div>
      }

      @if (paciente(); as p) {
        <div class="card">
          <h2>Paciente</h2>
          <p>{{ p.nombres }} {{ p.apellidos }} · {{ p.sexo === 'F' ? 'Mujer' : p.sexo === 'M' ? 'Hombre' : 'Otro' }} ·
            nacido el {{ p.fecha_nacimiento }} · Sangre {{ p.tipo_sangre || '—' }}</p>
          @if (p.alergias) { <div class="alerta aviso">Alergias: {{ p.alergias }}</div> }
        </div>
      }

      <form class="card" (ngSubmit)="guardarNota()">
        <div class="entre"><h2>Nota de la consulta</h2>
          @if (nota.updated_at) { <small class="muted">Guardada {{ fechaHora(nota.updated_at) }}</small> }</div>
        <div class="campo"><label for="nm">Motivo de la consulta</label>
          <input id="nm" name="nm" maxlength="500" [(ngModel)]="nota.motivo" placeholder="Por qué viene el paciente" /></div>
        <div class="campo"><label for="ns">Molestias principales</label>
          <textarea id="ns" name="ns" maxlength="2000" rows="3" [(ngModel)]="nota.sintomas" placeholder="Qué siente, desde cuándo, cómo"></textarea></div>
        <div class="campo"><label for="ne">Observaciones y examen físico</label>
          <textarea id="ne" name="ne" maxlength="2000" rows="3" [(ngModel)]="nota.examen_fisico"></textarea></div>
        <div class="campo"><label for="nd">Diagnóstico</label>
          <input id="nd" name="nd" maxlength="500" [(ngModel)]="nota.diagnostico" placeholder="Ej.: J06.9 Infección respiratoria aguda" /></div>
        <button type="submit" [disabled]="ocupado()">Guardar nota</button>
      </form>

      <div class="card">
        <h2>Receta y tratamiento</h2>
        <p class="muted">Si no hacen falta exámenes (por ejemplo, una gripe), recete aquí mismo. La receta le llega al paciente
          por correo y queda como su tratamiento en el portal. Si ordena exámenes, también podrá recetar al ver los resultados.</p>
        @if (c.solicitud_id && ['PAGADA', 'COMPLETADA'].includes(c.solicitud_estado ?? '')) {
          <app-receta [solicitudId]="c.solicitud_id" />
        } @else {
          <p class="alerta aviso">La receta se habilita cuando {{ c.origen === 'MEDICO' ? 'el control' : 'la consulta' }} está pagada.</p>
        }
        <details class="trat">
          <summary>Tratamiento sin medicamentos (dieta, reposo, terapia…)</summary>
          <form (ngSubmit)="guardarTratamiento()">
            <div class="campo"><label for="td">Diagnóstico</label><input id="td" name="td" maxlength="1000" [(ngModel)]="trat.diagnostico" required /></div>
            <div class="campo"><label for="ti">Indicaciones</label><textarea id="ti" name="ti" maxlength="2000" rows="3" [(ngModel)]="trat.indicaciones" required></textarea></div>
            <div class="fila">
              <div class="campo"><label for="tf">Hasta (opcional)</label><input id="tf" name="tf" type="date" [min]="hoy" [(ngModel)]="trat.fecha_fin" /></div>
              <div class="campo"><button type="submit" [disabled]="!trat.diagnostico.trim() || !trat.indicaciones.trim() || ocupado()">Registrar tratamiento</button></div>
            </div>
          </form>
        </details>
      </div>

      <div class="dos">
        <div class="card">
          <h2>Exámenes de esta {{ c.origen === 'MEDICO' ? 'atención' : 'consulta' }}</h2>
          @if (c.origen === 'MEDICO') { <p class="muted">Los que ordenó en la consulta que originó este control.</p> }
          <table>
            @for (s of deEstaConsulta(); track s.solicitud_id) {
              <tr><td><strong>{{ s.codigo }}</strong><br /><small>{{ s.examenes_resumen }}</small></td>
                <td><span [class]="claseEstado(s.estado)">{{ textoEstado(s.estado) }}</span></td>
                <td class="acciones">
                  @if (s.examenes_listos) { <button class="chico" (click)="pdf(s)">Resultados (PDF)</button> }
                  <button class="secundario chico" (click)="abrir(s.solicitud_id)">Abrir</button></td></tr>
            } @empty { <tr><td class="vacio">Aún no ordena exámenes en esta consulta.</td></tr> }
          </table>
          <button type="button" class="secundario chico" (click)="verAnteriores.set(!verAnteriores())" [disabled]="!anteriores().length">
            {{ verAnteriores() ? 'Ocultar' : 'Ver' }} exámenes anteriores ({{ anteriores().length }})</button>
          @if (verAnteriores()) {
            <table>
              @for (s of anteriores(); track s.solicitud_id) {
                <tr><td><strong>{{ s.codigo }}</strong> <small class="muted">{{ fechaHora(s.created_at) }}</small><br /><small>{{ s.examenes_resumen }}</small></td>
                  <td><span [class]="claseEstado(s.estado)">{{ textoEstado(s.estado) }}</span></td>
                  <td class="acciones">
                    @if (s.examenes_listos) { <button class="chico" (click)="pdf(s)">PDF</button> }
                    <button class="secundario chico" (click)="abrir(s.solicitud_id)">Abrir</button></td></tr>
              }
            </table>
          }
          <h3>Tratamientos</h3>
          @for (t of tratamientos(); track t.tratamiento_id) {
            <p><strong>{{ t.diagnostico }}</strong> <small class="muted">({{ t.estado.toLowerCase() }}, desde {{ t.fecha_inicio }})</small></p>
          } @empty { <p class="muted">Sin tratamientos.</p> }
        </div>

        <div class="card">
          <h2>Ordenar exámenes</h2>
          <input type="search" placeholder="Buscar examen" [ngModel]="q()" (ngModelChange)="q.set($event)" class="buscar" />
          <div class="lista">
            @for (t of catalogoFiltrado(); track t.tipo_examen_id) {
              <label class="check"><input type="checkbox" [checked]="elegidos().has(t.tipo_examen_id)" (change)="alternar(t.tipo_examen_id)" />
                {{ t.nombre }} <small class="muted">{{ dinero(t.precio) }}{{ t.requiere_ayuno ? ' · ayuno' : '' }}</small></label>
            }
          </div>
          <div class="campo"><label for="lab">Dónde</label>
            <select id="lab" [(ngModel)]="laboratorioId">
              <option [ngValue]="null">En una de nuestras sucursales (el paciente elige cuál, el día y la hora)</option>
              @for (l of externos(); track l.laboratorio_id) {
                <option [ngValue]="l.laboratorio_id">{{ l.nombre }} (externo: se paga allá y sube el PDF)</option>
              }
            </select></div>
          <p>{{ elegidos().size }} examen(es) · {{ dinero(totalElegidos()) }}</p>
          <button (click)="ordenar()" [disabled]="!elegidos().size || ocupado()">Ordenar exámenes</button>
          @if (ordenada(); as o) {
            <p class="ok-texto">Ordenada {{ o.codigo }}. El paciente recibió un correo para elegir sucursal, día y hora y pagarla;
              los resultados le llegarán a usted.</p>
          }
        </div>
      </div>

      <div class="card">
        <h2>Agendar la cita de control</h2>
        <p class="muted">En su agenda. El control se cobra como una consulta: el paciente lo paga desde el portal hasta 2 horas
          antes; si no, se cancela solo y el turno se libera.</p>
        @if (diasControl().length) {
          <div class="fila">
            <div class="campo"><label for="dc">Fecha</label>
              <select id="dc" [ngModel]="dia()" (ngModelChange)="dia.set($event); franja.set(null)">
                @for (d of diasControl(); track d) { <option [value]="d">{{ d }}</option> }
              </select></div>
          </div>
          <div class="chips">
            @for (f of franjasDelDia(); track f.franja_id) {
              <button type="button" [class]="franja()?.franja_id === f.franja_id ? 'chip activo' : 'chip'" (click)="franja.set(f)">{{ hora(f.hora_inicio) }}</button>
            }
          </div>
          <div class="fila">
            <div class="campo"><label for="mc">Motivo del control</label><input id="mc" maxlength="200" [(ngModel)]="motivoControl" />
              <small class="muted">{{ motivoControl.length }}/200</small></div>
            <div class="campo"><button (click)="agendar()" [disabled]="!franja() || ocupado()">
              Agendar control {{ franja() ? 'el ' + dia() + ' a las ' + hora(franja()!.hora_inicio) : '' }}</button></div>
          </div>
        } @else {
          <p class="muted">No tiene turnos libres en los próximos 3 meses. Genérelos en "Mi horario".</p>
        }
        @if (control(); as k) {
          <p class="ok-texto">Control agendado para el {{ k.fecha }} a las {{ hora(k.hora_inicio) }} ({{ dinero(k.solicitud_total) }}).
            El paciente recibió un correo para pagarlo.</p>
        }
      </div>
    } @else if (!error()) {
      <p class="muted">Cargando…</p>
    }
  `,
  styles: `
    .cabeza { margin-top: 12px; }
    .dos { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 16px; }
    @media (max-width: 860px) { .dos { grid-template-columns: 1fr; } }
    .lista { max-height: 260px; overflow-y: auto; border: 1px solid var(--borde); border-radius: 6px; padding: 6px 10px; margin: 8px 0; }
    .check { display: flex; gap: 8px; align-items: baseline; padding: 3px 0; }
    .buscar { width: 100%; }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; margin: 8px 0; }
    .chip { background: #fff; color: var(--tinta); border: 1px solid var(--borde); padding: 4px 10px; font-size: 13px; }
    .chip.activo { background: var(--verde); color: #fff; border-color: var(--verde); }
    .ok-texto { color: var(--verde); font-weight: 600; }
    .acciones { white-space: nowrap; text-align: right; }
    .acciones button { margin-left: 4px; }
    .trat { margin-top: 12px; border-top: 1px solid var(--borde); padding-top: 10px; }
    .trat summary { cursor: pointer; font-weight: 600; color: var(--verde); }
    textarea { width: 100%; }
  `,
})
export class Consulta implements OnInit {
  readonly id = input.required<string>();
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  protected readonly auth = inject(AuthService);
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly hora = hora;
  protected readonly dinero = dinero;
  protected readonly fechaHora = fechaHora;
  protected readonly hoy = hoyIso();

  protected readonly cita = signal<Cita | null>(null);
  protected readonly paciente = signal<Paciente | null>(null);
  protected readonly historial = signal<SolicitudResumen[]>([]);
  protected readonly tratamientos = signal<Tratamiento[]>([]);
  protected readonly catalogo = signal<TipoExamen[]>([]);
  protected readonly elegidos = signal(new Set<number>());
  protected readonly q = signal('');
  protected readonly franjas = signal<Franja[]>([]);
  protected readonly dia = signal<string | null>(null);
  protected readonly franja = signal<Franja | null>(null);
  protected readonly ordenada = signal<SolicitudResumen | null>(null);
  protected readonly control = signal<Cita | null>(null);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected readonly ocupado = signal(false);
  protected readonly verAnteriores = signal(false);
  protected motivoControl = 'Control con resultados';
  protected readonly laboratorios = signal<Laboratorio[]>([]);
  protected readonly externos = computed(() => this.laboratorios().filter((l) => !l.propio));
  protected laboratorioId: number | null = null;
  protected nota: Nota = { motivo: null, sintomas: null, examen_fisico: null, diagnostico: null, updated_at: null };
  protected trat = { diagnostico: '', indicaciones: '', fecha_fin: '' };

  /** Consulta a la que pertenecen los exámenes de esta atención: ella misma o, en un control, la que lo originó. */
  private readonly consultaBase = computed(() => {
    const c = this.cita();
    return c ? [c.cita_id, c.cita_origen_id].filter((x): x is number => !!x) : [];
  });
  protected readonly deEstaConsulta = computed(() =>
    this.historial().filter((s) => s.consulta_cita_id && this.consultaBase().includes(s.consulta_cita_id)));
  protected readonly anteriores = computed(() =>
    this.historial().filter((s) => !s.consulta_cita_id || !this.consultaBase().includes(s.consulta_cita_id)));

  protected readonly catalogoFiltrado = computed(() => {
    const q = this.q().trim().toLowerCase();
    return this.catalogo().filter((t) => t.codigo !== 'CONS-MED' && (!q || `${t.nombre} ${t.categoria} ${t.codigo}`.toLowerCase().includes(q)));
  });
  protected readonly totalElegidos = computed(() =>
    this.catalogo().filter((t) => this.elegidos().has(t.tipo_examen_id)).reduce((a, t) => a + Number(t.precio), 0));
  protected readonly diasControl = computed(() => [...new Set(this.franjas().map((f) => f.fecha))]);
  protected readonly franjasDelDia = computed(() => this.franjas().filter((f) => f.fecha === this.dia()));

  async ngOnInit() {
    try {
      const c = await this.api.get<Cita>(`/api/citas/${this.id()}`);
      this.cita.set(c);
      const [pacientes, historial, tratamientos, catalogo, franjas, labs, nota] = await Promise.all([
        this.api.get<Paciente[]>('/api/pacientes', { cedula: c.cedula }),
        this.api.get<SolicitudResumen[]>('/api/solicitudes', { cedula: c.cedula, tipo: 'EXAMENES' }),
        this.api.get<Tratamiento[]>('/api/tratamientos', { paciente_id: c.paciente_id }),
        this.api.get<TipoExamen[]>('/api/examenes/catalogo'),
        this.api.get<Franja[]>('/api/citas/franjas', { medico_id: this.auth.usuario()?.medico_id, dias: 92 }),
        this.api.get<Laboratorio[]>('/api/laboratorios'),
        this.api.get<Nota>(`/api/citas/${this.id()}/nota`),
      ]);
      this.paciente.set(pacientes[0] ?? null);
      this.historial.set(historial);
      this.tratamientos.set(tratamientos);
      this.catalogo.set(catalogo);
      this.laboratorios.set(labs);
      this.nota = nota;
      // El control, después de la fecha de esta consulta.
      this.franjas.set(franjas.filter((f) => f.fecha > c.fecha));
      this.dia.set(this.diasControl()[0] ?? null);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  protected alternar(id: number) {
    const s = new Set(this.elegidos());
    if (s.has(id)) s.delete(id); else s.add(id);
    this.elegidos.set(s);
  }

  async guardarNota() {
    await this.paso(async () => {
      this.nota = await this.api.put<Nota>(`/api/citas/${this.id()}/nota`, {
        motivo: this.nota.motivo || null, sintomas: this.nota.sintomas || null,
        examen_fisico: this.nota.examen_fisico || null, diagnostico: this.nota.diagnostico || null,
      });
      this.aviso.set('Nota de la consulta guardada.');
    });
  }

  async guardarTratamiento() {
    await this.paso(async () => {
      const t = await this.api.post<Tratamiento>('/api/tratamientos', {
        paciente_id: this.cita()!.paciente_id, diagnostico: this.trat.diagnostico.trim(), indicaciones: this.trat.indicaciones.trim(),
        fecha_inicio: this.hoy, fecha_fin: this.trat.fecha_fin || null, solicitud_id: this.cita()!.solicitud_id,
      });
      this.tratamientos.update((x) => [t, ...x]);
      this.trat = { diagnostico: '', indicaciones: '', fecha_fin: '' };
      this.aviso.set('Tratamiento registrado: el paciente lo ve en su portal.');
    });
  }

  async ordenar() {
    await this.paso(async () => {
      const s = await this.api.post<SolicitudResumen>('/api/solicitudes', {
        paciente_id: this.cita()!.paciente_id, examenes: [...this.elegidos()], laboratorio_id: this.laboratorioId,
        consulta_cita_id: Number(this.id()), observaciones: `Ordenados en la consulta del ${this.cita()!.fecha}`,
      });
      this.ordenada.set(s);
      this.elegidos.set(new Set());
      this.historial.update((h) => [s, ...h]);
    });
  }

  async agendar() {
    await this.paso(async () => {
      const k = await this.api.post<Cita>('/api/citas/control', {
        paciente_id: this.cita()!.paciente_id, franja_id: this.franja()!.franja_id, motivo: this.motivoControl || null,
        cita_origen_id: Number(this.id()),
      });
      this.control.set(k);
      this.franjas.update((x) => x.filter((f) => f.franja_id !== k.franja_id));
      this.franja.set(null);
    });
  }

  async finalizar() {
    await this.paso(async () => {
      this.cita.set(await this.api.post<Cita>(`/api/citas/${this.id()}/atender`));
      this.aviso.set('Consulta finalizada.');
    });
  }

  /** El PDF se abre en otra pestaña: la consulta sigue abierta aquí. */
  async pdf(s: SolicitudResumen) {
    try {
      await this.api.abrirArchivo(`/api/solicitudes/${s.solicitud_id}/pdf`);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  private async paso(accion: () => Promise<void>) {
    this.error.set('');
    this.aviso.set('');
    this.ocupado.set(true);
    try {
      await accion();
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.ocupado.set(false);
    }
  }

  /** El detalle vuelve a esta consulta (no a la lista de solicitudes). */
  abrir(id: number) {
    this.router.navigate(['/solicitudes', id], { queryParams: { volver: `/consulta/${this.id()}` } });
  }

  volver() {
    this.router.navigate(['/agenda']);
  }
}
