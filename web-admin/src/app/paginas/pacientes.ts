import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, dinero, fechaHora, hoyIso, textoEstado } from '../core/formato';
import { Paciente, SolicitudResumen, Tratamiento } from '../core/modelos';

@Component({
  selector: 'app-pacientes',
  imports: [FormsModule, RouterLink],
  template: `
    <h1>Pacientes y tratamientos</h1>
    <p class="sub">Historial de exámenes y seguimiento médico.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    <form class="card fila" (ngSubmit)="buscar()">
      <div class="campo"><label for="b">Cédula o apellido</label><input id="b" name="b" [(ngModel)]="busqueda" /></div>
      <div class="campo"><button type="submit">Buscar</button></div>
    </form>
    @if (!paciente()) {
      <div class="card tabla-scroll">
        <table>
          <thead><tr><th>Paciente</th><th>Cédula</th><th>Nacimiento</th><th>Sangre</th><th>Correo</th></tr></thead>
          <tbody>
            @for (p of pacientes(); track p.paciente_id) {
              <tr class="clic" (click)="abrir(p)">
                <td><strong>{{ p.apellidos }} {{ p.nombres }}</strong></td><td>{{ p.cedula }}</td>
                <td>{{ p.fecha_nacimiento }}</td><td>{{ p.tipo_sangre }}</td><td>{{ p.email }}</td>
              </tr>
            } @empty { <tr><td colspan="5" class="vacio">Busque un paciente.</td></tr> }
          </tbody>
        </table>
      </div>
    } @else {
      @let p = paciente()!;
      <div class="card entre">
        <div>
          <h2>{{ p.nombres }} {{ p.apellidos }}</h2>
          <span class="muted">CI {{ p.cedula }} · {{ p.fecha_nacimiento }} · Sangre {{ p.tipo_sangre ?? '—' }}
            @if (p.alergias) { · <strong class="fuera">Alergias: {{ p.alergias }}</strong> }</span>
        </div>
        <button class="secundario" (click)="paciente.set(null)">← Otro paciente</button>
      </div>

      <div class="card tabla-scroll">
        <h3>Solicitudes de exámenes</h3>
        <table>
          @for (s of solicitudes(); track s.solicitud_id) {
            <tr>
              <td><a [routerLink]="['/solicitudes', s.solicitud_id]">{{ s.codigo }}</a></td>
              <td>{{ fechaHora(s.created_at) }}</td><td>{{ dinero(s.total) }}</td>
              <td><span [class]="claseEstado(s.estado)">{{ textoEstado(s.estado) }}</span></td>
            </tr>
          } @empty { <tr><td class="vacio">Sin solicitudes.</td></tr> }
        </table>
      </div>

      @if (auth.tiene('MEDICO', 'ADMIN')) {
        <div class="card">
          <h3>Tratamientos</h3>
          @for (t of tratamientos(); track t.tratamiento_id) {
            <div class="trat">
              <div class="entre">
                <strong>{{ t.diagnostico }}</strong>
                <span [class]="claseEstado(t.estado)">{{ textoEstado(t.estado) }}</span>
              </div>
              <div>{{ t.indicaciones }}</div>
              <small class="muted">{{ t.medico }} · desde {{ t.fecha_inicio }}{{ t.fecha_fin ? ' hasta ' + t.fecha_fin : '' }}</small>
              @if (auth.tiene('MEDICO') && t.medico_id === auth.usuario()?.medico_id && t.estado === 'ACTIVO') {
                <div class="fila"><button class="secundario chico" (click)="cambiarEstado(t, 'FINALIZADO')">Finalizar</button>
                  <button class="secundario chico" (click)="cambiarEstado(t, 'SUSPENDIDO')">Suspender</button></div>
              }
            </div>
          } @empty { <p class="muted">Sin tratamientos registrados.</p> }

          @if (auth.tiene('MEDICO')) {
            <form (ngSubmit)="nuevoTratamiento()">
              <h3>Nuevo tratamiento</h3>
              <div class="campo"><label>Diagnóstico</label><input name="d" [(ngModel)]="nuevo.diagnostico" required /></div>
              <div class="campo"><label>Indicaciones</label><textarea name="i" [(ngModel)]="nuevo.indicaciones" required></textarea></div>
              <div class="fila">
                <div class="campo"><label>Inicio</label><input type="date" name="fi" [(ngModel)]="nuevo.fecha_inicio" required /></div>
                <div class="campo"><label>Fin (opcional)</label><input type="date" name="ff" [(ngModel)]="nuevo.fecha_fin" /></div>
                <div class="campo"><label>Solicitud relacionada</label>
                  <select name="s" [(ngModel)]="nuevo.solicitud_id"><option [ngValue]="null">Ninguna</option>
                    @for (s of solicitudes(); track s.solicitud_id) { <option [ngValue]="s.solicitud_id">{{ s.codigo }}</option> }
                  </select></div>
              </div>
              <button type="submit" [disabled]="!nuevo.diagnostico || !nuevo.indicaciones">Registrar tratamiento</button>
            </form>
          }
        </div>
      }
    }
  `,
  styles: `.trat { border-left: 3px solid var(--verde); padding: 6px 12px; margin-bottom: 12px; } form h3 { margin-top: 18px; }`,
})
export class Pacientes {
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly fechaHora = fechaHora;
  protected readonly dinero = dinero;
  protected busqueda = '';
  protected readonly pacientes = signal<Paciente[]>([]);
  protected readonly paciente = signal<Paciente | null>(null);
  protected readonly solicitudes = signal<SolicitudResumen[]>([]);
  protected readonly tratamientos = signal<Tratamiento[]>([]);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected nuevo = this.vacio();

  constructor() {
    this.buscar();
  }

  private vacio() {
    return { diagnostico: '', indicaciones: '', fecha_inicio: hoyIso(), fecha_fin: '', solicitud_id: null as number | null };
  }

  async buscar() {
    this.error.set('');
    const b = this.busqueda.trim();
    try {
      this.pacientes.set(await this.api.get<Paciente[]>('/api/pacientes', /^\d{10}$/.test(b) ? { cedula: b } : { q: b }));
      this.paciente.set(null);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async abrir(p: Paciente) {
    this.paciente.set(p);
    this.aviso.set('');
    this.nuevo = this.vacio();
    try {
      this.solicitudes.set(await this.api.get<SolicitudResumen[]>('/api/solicitudes', { cedula: p.cedula }));
      if (this.auth.tiene('MEDICO', 'ADMIN')) {
        this.tratamientos.set(await this.api.get<Tratamiento[]>('/api/tratamientos', { paciente_id: p.paciente_id }));
      }
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async nuevoTratamiento() {
    this.error.set('');
    try {
      await this.api.post('/api/tratamientos', {
        paciente_id: this.paciente()!.paciente_id, diagnostico: this.nuevo.diagnostico, indicaciones: this.nuevo.indicaciones,
        fecha_inicio: this.nuevo.fecha_inicio, fecha_fin: this.nuevo.fecha_fin || null, solicitud_id: this.nuevo.solicitud_id,
      });
      this.aviso.set('Tratamiento registrado.');
      await this.abrir(this.paciente()!);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async cambiarEstado(t: Tratamiento, estado: string) {
    try {
      await this.api.patch(`/api/tratamientos/${t.tratamiento_id}`, { estado });
      await this.abrir(this.paciente()!);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
