import { Component, computed, inject, input, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, dinero, fechaHora, hora, textoEstado } from '../core/formato';
import { Cita, Franja, Laboratorio, Paciente, SolicitudResumen, TipoExamen, Tratamiento } from '../core/modelos';

/**
 * Consulta médica: el médico revisa al paciente, le ordena exámenes y le agenda la cita de control.
 * Los resultados le llegan al médico por correo y aparecen en su inicio; el paciente solo vuelve al control.
 */
@Component({
  selector: 'app-consulta',
  imports: [FormsModule],
  template: `
    <button type="button" class="secundario chico" (click)="volver()">← Mis consultas</button>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    @if (cita(); as c) {
      <div class="entre cabeza">
        <div>
          <h1>{{ c.origen === 'MEDICO' ? 'Control' : 'Consulta' }}: {{ c.paciente }}
            <span [class]="claseEstado(c.estado)">{{ textoEstado(c.estado) }}</span></h1>
          <p class="sub">{{ c.fecha }} · {{ hora(c.hora_inicio) }} · CI {{ c.cedula }}
            @if (c.motivo) { · Motivo: {{ c.motivo }} }</p>
        </div>
        @if (c.estado === 'CONFIRMADA') {
          <button (click)="finalizar()">Finalizar consulta</button>
        }
      </div>
      @if (c.estado === 'PENDIENTE_PAGO') {
        <div class="alerta aviso">El paciente aún no paga la consulta. Puede revisar su historial, pero solo podrá cerrarla cuando esté pagada.</div>
      }

      @if (paciente(); as p) {
        <div class="card">
          <h2>Paciente</h2>
          <p>{{ p.nombres }} {{ p.apellidos }} · {{ p.sexo === 'F' ? 'Mujer' : p.sexo === 'M' ? 'Hombre' : 'Otro' }} ·
            nacido el {{ p.fecha_nacimiento }} · Sangre {{ p.tipo_sangre || '—' }}</p>
          @if (p.alergias) { <div class="alerta aviso">Alergias: {{ p.alergias }}</div> }
        </div>
      }

      <div class="dos">
        <div class="card">
          <h2>Exámenes anteriores</h2>
          <table>
            @for (s of historial(); track s.solicitud_id) {
              <tr><td><strong>{{ s.codigo }}</strong><br /><small>{{ s.examenes_resumen }}</small></td>
                <td><span [class]="claseEstado(s.estado)">{{ textoEstado(s.estado) }}</span></td>
                <td><button class="secundario chico" (click)="abrir(s.solicitud_id)">Abrir</button></td></tr>
            } @empty { <tr><td class="vacio">Sin exámenes anteriores.</td></tr> }
          </table>
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
          <div class="campo"><label for="lab">Laboratorio</label>
            <select id="lab" [(ngModel)]="laboratorioId">
              @for (l of laboratorios(); track l.laboratorio_id) {
                <option [ngValue]="l.laboratorio_id">{{ l.nombre }}{{ l.propio ? ' (nuestro)' : ' (externo: se paga allá y sube el PDF)' }}</option>
              }
            </select></div>
          <p>{{ elegidos().size }} examen(es) · {{ dinero(totalElegidos()) }}</p>
          <button (click)="ordenar()" [disabled]="!elegidos().size || ocupado()">Ordenar exámenes</button>
          @if (ordenada(); as o) {
            <p class="ok-texto">Ordenada {{ o.codigo }}. El paciente recibió un correo para pagarla; los resultados le llegarán a usted.</p>
          }
        </div>
      </div>

      <div class="card">
        <h2>Agendar la cita de control</h2>
        <p class="muted">En su agenda. Está incluida en la consulta: queda confirmada y sin costo para el paciente.</p>
        @if (diasControl().length) {
          <div class="chips">
            @for (d of diasControl(); track d) {
              <button type="button" [class]="d === dia() ? 'chip activo' : 'chip'" (click)="dia.set(d); franja.set(null)">{{ d }}</button>
            }
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
          <p class="muted">No tiene turnos libres en los próximos 31 días. El administrador los genera en "Catálogo y franjas".</p>
        }
        @if (control(); as k) {
          <p class="ok-texto">Control agendado y confirmado para el {{ k.fecha }} a las {{ hora(k.hora_inicio) }}. El paciente recibió un correo.</p>
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
  protected motivoControl = 'Control con resultados';
  protected readonly laboratorios = signal<Laboratorio[]>([]);
  protected laboratorioId: number | null = null;

  protected readonly catalogoFiltrado = computed(() => {
    const q = this.q().trim().toLowerCase();
    return this.catalogo().filter((t) => !q || `${t.nombre} ${t.categoria} ${t.codigo}`.toLowerCase().includes(q));
  });
  protected readonly totalElegidos = computed(() =>
    this.catalogo().filter((t) => this.elegidos().has(t.tipo_examen_id)).reduce((a, t) => a + Number(t.precio), 0));
  protected readonly diasControl = computed(() => [...new Set(this.franjas().map((f) => f.fecha))]);
  protected readonly franjasDelDia = computed(() => this.franjas().filter((f) => f.fecha === this.dia()));

  async ngOnInit() {
    try {
      const c = await this.api.get<Cita>(`/api/citas/${this.id()}`);
      this.cita.set(c);
      const [pacientes, historial, tratamientos, catalogo, franjas] = await Promise.all([
        this.api.get<Paciente[]>('/api/pacientes', { cedula: c.cedula }),
        this.api.get<SolicitudResumen[]>('/api/solicitudes', { cedula: c.cedula, tipo: 'EXAMENES' }),
        this.api.get<Tratamiento[]>('/api/tratamientos', { paciente_id: c.paciente_id }),
        this.api.get<TipoExamen[]>('/api/examenes/catalogo'),
        this.api.get<Franja[]>('/api/citas/franjas', { medico_id: this.auth.usuario()?.medico_id, dias: 31 }),
      ]);
      this.paciente.set(pacientes[0] ?? null);
      this.historial.set(historial);
      this.tratamientos.set(tratamientos);
      this.catalogo.set(catalogo);
      this.laboratorios.set(await this.api.get<Laboratorio[]>('/api/laboratorios'));
      this.laboratorioId = this.laboratorios().find((l) => l.propio)?.laboratorio_id ?? null;
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

  async ordenar() {
    await this.paso(async () => {
      const s = await this.api.post<SolicitudResumen>('/api/solicitudes', {
        paciente_id: this.cita()!.paciente_id, examenes: [...this.elegidos()],
        laboratorio_id: this.laboratorios().find((l) => l.laboratorio_id === this.laboratorioId && !l.propio)?.laboratorio_id ?? null,
        observaciones: `Ordenados en la consulta del ${this.cita()!.fecha}`,
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

  abrir(id: number) {
    this.router.navigate(['/solicitudes', id]);
  }

  volver() {
    this.router.navigate(['/agenda']);
  }
}
