import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, dinero, fechaHora, hoyIso, textoEstado } from '../core/formato';
import { Paciente, SolicitudResumen, Tratamiento } from '../core/modelos';
import { Pagina, paginaVacia, Paginador, POR_PAGINA } from '../core/paginador';

@Component({
  selector: 'app-pacientes',
  imports: [FormsModule, Paginador],
  template: `
    <h1>{{ auth.tiene('MEDICO') ? 'Pacientes y tratamientos' : 'Pacientes' }}</h1>
    <p class="sub">{{ auth.tiene('MEDICO') ? 'Historial de exámenes y seguimiento médico.'
      : 'Datos del paciente e historial de exámenes. Los tratamientos y recetas solo los ven el médico y el paciente.' }}</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    <form class="card fila" (ngSubmit)="buscar(1)">
      <div class="campo"><label for="b">Cédula, nombre o apellido</label><input id="b" name="b" maxlength="100" [(ngModel)]="busqueda" /></div>
      <div class="campo"><button type="submit">Buscar</button></div>
    </form>
    @if (!paciente()) {
      <div class="card tabla-scroll">
        <table>
          <thead><tr><th>Paciente</th><th>Cédula</th><th>Nacimiento</th><th>Sangre</th><th>Correo</th><th></th></tr></thead>
          <tbody>
            @for (p of pacientes().items; track p.paciente_id) {
              <tr class="clic" (click)="abrir(p)">
                <td><strong>{{ p.apellidos }} {{ p.nombres }}</strong></td><td>{{ p.cedula }}</td>
                <td>{{ p.fecha_nacimiento }}</td><td>{{ p.tipo_sangre }}</td><td>{{ p.email }}</td>
                <td><button type="button" class="secundario chico" (click)="abrir(p); $event.stopPropagation()">Ver historial</button></td>
              </tr>
            } @empty { <tr><td colspan="6" class="vacio">No se encontraron pacientes.</td></tr> }
          </tbody>
        </table>
        <app-paginador [pagina]="pacientes()" (cambiar)="buscar($event)" />
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
          <thead><tr><th>Código</th><th>Exámenes</th><th>Fecha</th><th class="num">Total</th><th>Estado</th><th></th></tr></thead>
          @for (s of solicitudes(); track s.solicitud_id) {
            <tr>
              <td><strong>{{ s.codigo }}</strong></td><td><small>{{ s.examenes_resumen }}</small></td>
              <td>{{ fechaHora(s.created_at) }}</td><td class="num">{{ dinero(s.total) }}</td>
              <td><span [class]="claseEstado(s.estado)">{{ textoEstado(s.estado) }}</span></td>
              <td><button type="button" class="secundario chico" (click)="verSolicitud(s.solicitud_id)">Abrir</button></td>
            </tr>
          } @empty { <tr><td colspan="6" class="vacio">Sin solicitudes.</td></tr> }
        </table>
      </div>

      @if (auth.tiene('MEDICO')) {
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
              @if (solicitudDe(t); as s) {
                <div class="base">Basado en <strong>{{ s.codigo }}</strong>: {{ s.examenes_resumen }} ({{ fechaHora(s.created_at) }})
                  <button type="button" class="secundario chico" (click)="verSolicitud(s.solicitud_id)">Ver resultados</button></div>
              } @else {
                <div class="base muted">Sin solicitud de exámenes asociada.</div>
              }
              @if (auth.tiene('MEDICO') && t.medico_id === auth.usuario()?.medico_id && t.estado === 'ACTIVO') {
                <div class="fila"><button class="secundario chico" (click)="cambiarEstado(t, 'FINALIZADO')">Finalizar</button>
                  <button class="secundario chico" (click)="cambiarEstado(t, 'SUSPENDIDO')">Suspender</button></div>
              }
            </div>
          } @empty { <p class="muted">Sin tratamientos registrados.</p> }

          @if (auth.tiene('MEDICO')) {
            <form (ngSubmit)="nuevoTratamiento()">
              <h3>Nuevo tratamiento</h3>
              <div class="campo"><label>Exámenes en los que se basa</label>
                <select name="s" [(ngModel)]="nuevo.solicitud_id"><option [ngValue]="null">Ninguno (tratamiento sin exámenes)</option>
                  @for (s of solicitudes(); track s.solicitud_id) {
                    <option [ngValue]="s.solicitud_id">{{ s.codigo }} · {{ s.examenes_resumen }} · {{ fechaHora(s.created_at) }} · {{ textoEstado(s.estado) }}</option>
                  }
                </select>
                <small class="muted">Por defecto, la última solicitud con resultados. Para ver los valores, use «Abrir» en la tabla de arriba.</small></div>
              <div class="campo"><label>Diagnóstico</label><input name="d" maxlength="1000" [(ngModel)]="nuevo.diagnostico" required /></div>
              <div class="campo"><label>Indicaciones</label><textarea name="i" maxlength="2000" [(ngModel)]="nuevo.indicaciones" required></textarea></div>
              <div class="fila">
                <div class="campo"><label>Inicio</label><input type="date" name="fi" [(ngModel)]="nuevo.fecha_inicio" required /></div>
                <div class="campo"><label>Fin (opcional)</label><input type="date" name="ff" [(ngModel)]="nuevo.fecha_fin" /></div>
              </div>
              <button type="submit" [disabled]="!nuevo.diagnostico || !nuevo.indicaciones">Registrar tratamiento</button>
            </form>
          }
        </div>
      }
    }
  `,
  styles: `.trat { border-left: 3px solid var(--verde); padding: 6px 12px; margin-bottom: 12px; } form h3 { margin-top: 18px; }
    .base { margin-top: 4px; font-size: 13px; } .base button { margin-left: 6px; }`,
})
export class Pacientes {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  protected readonly auth = inject(AuthService);
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly fechaHora = fechaHora;
  protected readonly dinero = dinero;
  protected busqueda = '';
  protected readonly pacientes = signal<Pagina<Paciente>>(paginaVacia());
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

  async buscar(pagina = 1) {
    this.error.set('');
    const b = this.busqueda.trim();
    try {
      if (/^\d{10}$/.test(b)) {
        const lista = await this.api.get<Paciente[]>('/api/pacientes', { cedula: b });
        this.pacientes.set({ items: lista, total: lista.length, pagina: 1, por_pagina: POR_PAGINA, paginas: 1 });
      } else {
        this.pacientes.set(await this.api.get<Pagina<Paciente>>('/api/pacientes', { q: b, pagina, por_pagina: POR_PAGINA }));
      }
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
      const solicitudes = await this.api.get<SolicitudResumen[]>('/api/solicitudes', { cedula: p.cedula });
      this.solicitudes.set(solicitudes);
      // Por defecto, el tratamiento se basa en la última solicitud que ya tiene resultados.
      this.nuevo.solicitud_id =
        solicitudes.find((s) => ['COMPLETADA', 'EN_PROCESO'].includes(s.estado))?.solicitud_id ?? null;
      if (this.auth.tiene('MEDICO')) {
        this.tratamientos.set(await this.api.get<Tratamiento[]>('/api/tratamientos', { paciente_id: p.paciente_id }));
      }
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  protected solicitudDe(t: Tratamiento): SolicitudResumen | undefined {
    return t.solicitud_id ? this.solicitudes().find((s) => s.solicitud_id === t.solicitud_id) : undefined;
  }

  verSolicitud(id: number) {
    this.router.navigate(['/solicitudes', id]);
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
