import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { SoloLetras, SoloNumeros } from '../core/entrada';
import { Router } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { dinero } from '../core/formato';
import { Paciente, Solicitud, TipoExamen } from '../core/modelos';

@Component({
  selector: 'app-nueva-solicitud',
  imports: [FormsModule, SoloNumeros, SoloLetras],
  template: `
    <h1>Nueva solicitud de exámenes</h1>
    <p class="sub">Para pacientes atendidos en ventanilla o por orden médica.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }

    <div class="card">
      <h2>1. Paciente</h2>
      <form class="fila" (ngSubmit)="buscarPaciente()">
        <div class="campo"><label for="b">Cédula o apellido</label><input id="b" name="b" [(ngModel)]="busqueda" required /></div>
        <div class="campo"><button type="submit" class="secundario">Buscar</button></div>
      </form>
      @if (pacientes().length && !paciente()) {
        <table>
          @for (p of pacientes(); track p.paciente_id) {
            <tr class="clic" (click)="paciente.set(p)"><td>{{ p.apellidos }} {{ p.nombres }}</td><td>{{ p.cedula }}</td><td>{{ p.email }}</td></tr>
          }
        </table>
      }
      @if (paciente(); as p) {
        <div class="alerta ok">Paciente: <strong>{{ p.nombres }} {{ p.apellidos }}</strong> (CI {{ p.cedula }})
          @if (p.alergias) { · Alergias: {{ p.alergias }} }
          <button class="secundario chico" (click)="paciente.set(null)">Cambiar</button></div>
      }
      @if (!paciente()) {
        <button type="button" class="secundario chico" (click)="nuevoPaciente.set(!nuevoPaciente())">
          {{ nuevoPaciente() ? 'Cerrar' : '+ Registrar paciente de ventanilla' }}</button>
        @if (nuevoPaciente()) {
          <form class="registro" (ngSubmit)="registrar()">
            <p class="muted">Queda registrado sin cuenta; si luego quiere usar el portal, se registra con la misma cédula.</p>
            <div class="fila">
              <div class="campo"><label for="rc">Cédula</label><input id="rc" name="rc" soloNumeros [(ngModel)]="np.cedula" maxlength="10" required /></div>
              <div class="campo"><label for="rn">Nombres</label><input id="rn" name="rn" soloLetras [(ngModel)]="np.nombres" required /></div>
              <div class="campo"><label for="ra">Apellidos</label><input id="ra" name="ra" soloLetras [(ngModel)]="np.apellidos" required /></div>
            </div>
            <div class="fila">
              <div class="campo"><label for="rf">Nacimiento</label><input id="rf" name="rf" type="date" [(ngModel)]="np.fecha_nacimiento" required /></div>
              <div class="campo"><label for="rs">Sexo</label><select id="rs" name="rs" [(ngModel)]="np.sexo">
                <option value="F">Femenino</option><option value="M">Masculino</option><option value="O">Sin especificar</option></select></div>
              <div class="campo"><label for="rt">Teléfono</label><input id="rt" name="rt" soloNumeros maxlength="10" [(ngModel)]="np.telefono" /></div>
            </div>
            <div class="fila">
              <div class="campo"><label for="re">Correo (para la factura y los resultados)</label><input id="re" name="re" type="email" [(ngModel)]="np.email" /></div>
              <div class="campo"><label for="rd">Dirección</label><input id="rd" name="rd" [(ngModel)]="np.direccion" /></div>
            </div>
            <button type="submit" [disabled]="!np.cedula || !np.nombres || !np.apellidos || !np.fecha_nacimiento">Registrar paciente</button>
          </form>
        }
      }
    </div>

    <div class="card">
      <h2>2. Exámenes</h2>
      <div class="examenes">
        @for (t of catalogo(); track t.tipo_examen_id) {
          <label class="examen" [class.sel]="elegidos().has(t.tipo_examen_id)">
            <input type="checkbox" [checked]="elegidos().has(t.tipo_examen_id)" (change)="alternar(t.tipo_examen_id)" />
            <span><strong>{{ t.nombre }}</strong><br /><small class="muted">{{ t.categoria }} · {{ dinero(t.precio) }}
              @if (t.requiere_ayuno) { · requiere ayuno }</small></span>
          </label>
        }
      </div>
      <div class="campo"><label for="o">Observaciones</label><textarea id="o" [(ngModel)]="observaciones" name="obs"></textarea></div>
      <div class="entre">
        <strong>Total: {{ dinero(total()) }}</strong>
        <button (click)="crear()" [disabled]="!paciente() || !elegidos().size || creando()">Crear solicitud</button>
      </div>
    </div>
  `,
  styles: `
    .examenes { display: grid; gap: 8px; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); margin-bottom: 14px; }
    .examen { display: flex; gap: 10px; align-items: start; border: 1px solid var(--borde); border-radius: 6px; padding: 10px; cursor: pointer; }
    .examen.sel { border-color: var(--verde); background: var(--verde-suave); }
    .alerta button { margin-left: 8px; }
    .registro { margin-top: 12px; border-top: 1px dashed var(--borde); padding-top: 10px; }
  `,
})
export class NuevaSolicitud implements OnInit {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  protected readonly dinero = dinero;
  protected busqueda = '';
  protected observaciones = '';
  protected readonly catalogo = signal<TipoExamen[]>([]);
  protected readonly pacientes = signal<Paciente[]>([]);
  protected readonly paciente = signal<Paciente | null>(null);
  protected readonly elegidos = signal(new Set<number>());
  protected readonly total = computed(() =>
    this.catalogo().filter((t) => this.elegidos().has(t.tipo_examen_id)).reduce((s, t) => s + Number(t.precio), 0));
  protected readonly error = signal('');
  protected readonly creando = signal(false);
  protected readonly nuevoPaciente = signal(false);
  protected np = { cedula: '', nombres: '', apellidos: '', fecha_nacimiento: '', sexo: 'F', telefono: '', email: '', direccion: '' };

  async registrar() {
    this.error.set('');
    try {
      const p = await this.api.post<Paciente>('/api/pacientes', {
        ...this.np, telefono: this.np.telefono || null, email: this.np.email || null, direccion: this.np.direccion || null,
      });
      this.paciente.set(p);
      this.nuevoPaciente.set(false);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async ngOnInit() {
    try {
      this.catalogo.set(await this.api.get<TipoExamen[]>('/api/examenes/catalogo'));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async buscarPaciente() {
    this.error.set('');
    this.paciente.set(null);
    const b = this.busqueda.trim();
    try {
      const lista = await this.api.get<Paciente[]>('/api/pacientes', /^\d{10}$/.test(b) ? { cedula: b } : { q: b });
      this.pacientes.set(lista);
      if (lista.length === 1) this.paciente.set(lista[0]);
      if (!lista.length) this.error.set('No se encontró el paciente.');
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  alternar(id: number) {
    const s = new Set(this.elegidos());
    s.has(id) ? s.delete(id) : s.add(id);
    this.elegidos.set(s);
  }

  async crear() {
    this.creando.set(true);
    this.error.set('');
    try {
      const s = await this.api.post<Solicitud>('/api/solicitudes', {
        paciente_id: this.paciente()!.paciente_id, examenes: [...this.elegidos()], observaciones: this.observaciones || null,
      });
      this.router.navigate(['/solicitudes', s.solicitud_id]);
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.creando.set(false);
    }
  }
}
