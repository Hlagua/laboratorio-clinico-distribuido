import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { AuthService, NOMBRE_ROL, Rol } from '../core/auth';
import { fechaHora } from '../core/formato';
import { UsuarioAdmin } from '../core/modelos';

@Component({
  selector: 'app-usuarios',
  imports: [FormsModule],
  template: `
    <h1>Usuarios y roles</h1>
    <p class="sub">Una persona puede tener varios roles (por ejemplo, un médico que también es paciente).</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    <div class="card tabla-scroll">
      <table>
        <thead><tr><th>Usuario</th><th>Cédula</th><th>Roles</th><th>Último ingreso</th><th>Estado</th><th>Agregar rol</th></tr></thead>
        <tbody>
          @for (u of usuarios(); track u.usuario_id) {
            <tr>
              <td><strong>{{ u.nombre }}</strong><br /><small class="muted">{{ u.email }}</small></td>
              <td>{{ u.cedula }}</td>
              <td>@for (r of (u.roles ?? '').split(','); track r) { @if (r) { <span class="badge azul">{{ nombre(r) }}</span> } }</td>
              <td>{{ fechaHora(u.ultimo_login) }}</td>
              <td>
                <span [class]="u.activo ? 'badge' : 'badge rojo'">{{ u.activo ? 'activo' : 'inactivo' }}</span>
                @if (u.usuario_id !== auth.usuario()?.usuario_id) {
                  <br /><button class="secundario chico" (click)="activar(u)">{{ u.activo ? 'Desactivar' : 'Activar' }}</button>
                }
              </td>
              <td>
                <div class="fila mini">
                  <select [(ngModel)]="rolNuevo[u.usuario_id]"><option value="">—</option>
                    @for (r of roles; track r) { <option [value]="r">{{ nombre(r) }}</option> }</select>
                  @if (rolNuevo[u.usuario_id] === 'MEDICO' || rolNuevo[u.usuario_id] === 'LABORATORISTA') {
                    <input placeholder="Registro profesional" [(ngModel)]="registro[u.usuario_id]" />
                    <input placeholder="Especialidad / área" [(ngModel)]="area[u.usuario_id]" />
                  }
                  <button class="chico" [disabled]="!rolNuevo[u.usuario_id]" (click)="asignar(u)">Agregar</button>
                </div>
              </td>
            </tr>
          }
        </tbody>
      </table>
    </div>

    <form class="card" (ngSubmit)="crear()">
      <h2>Crear usuario</h2>
      <div class="fila">
        <div class="campo"><label>Cédula</label><input name="ce" [(ngModel)]="n.cedula" maxlength="10" required /></div>
        <div class="campo"><label>Nombres</label><input name="no" [(ngModel)]="n.nombres" required /></div>
        <div class="campo"><label>Apellidos</label><input name="ap" [(ngModel)]="n.apellidos" required /></div>
      </div>
      <div class="fila">
        <div class="campo"><label>Fecha de nacimiento</label><input type="date" name="fn" [(ngModel)]="n.fecha_nacimiento" required /></div>
        <div class="campo"><label>Sexo</label><select name="se" [(ngModel)]="n.sexo"><option value="F">F</option><option value="M">M</option><option value="O">Otro</option></select></div>
        <div class="campo"><label>Teléfono</label><input name="te" [(ngModel)]="n.telefono" /></div>
      </div>
      <div class="fila">
        <div class="campo"><label>Correo</label><input type="email" name="em" [(ngModel)]="n.email" required /></div>
        <div class="campo"><label>Contraseña inicial</label><input type="password" name="pw" [(ngModel)]="n.password" required autocomplete="new-password" /></div>
        <div class="campo"><label>Rol</label><select name="ro" [(ngModel)]="n.rol">
          @for (r of roles; track r) { <option [value]="r">{{ nombre(r) }}</option> }</select></div>
      </div>
      @if (n.rol === 'MEDICO' || n.rol === 'LABORATORISTA') {
        <div class="fila">
          <div class="campo"><label>Registro profesional</label><input name="rp" [(ngModel)]="n.registro_profesional" required /></div>
          <div class="campo"><label>{{ n.rol === 'MEDICO' ? 'Especialidad' : 'Área' }}</label><input name="es" [(ngModel)]="n.especialidad_o_area" /></div>
        </div>
      }
      <button type="submit">Crear usuario</button>
      <small class="muted"> La cédula se valida con el dígito verificador. Contraseña: mínimo 8 caracteres con letras y números.</small>
    </form>
  `,
  styles: `.mini { gap: 6px; flex-wrap: nowrap; } .mini input { width: 130px; } .badge { margin: 1px; }`,
})
export class Usuarios implements OnInit {
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly fechaHora = fechaHora;
  protected readonly roles: Rol[] = ['PACIENTE', 'LABORATORISTA', 'MEDICO', 'ADMIN'];
  protected readonly usuarios = signal<UsuarioAdmin[]>([]);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected rolNuevo: Record<number, string> = {};
  protected registro: Record<number, string> = {};
  protected area: Record<number, string> = {};
  protected n = this.vacio();

  ngOnInit() {
    this.cargar();
  }

  protected nombre(r: string) {
    return NOMBRE_ROL[r as Rol] ?? r;
  }

  private vacio() {
    return { cedula: '', nombres: '', apellidos: '', fecha_nacimiento: '', sexo: 'F', telefono: '', email: '', password: '',
      rol: 'LABORATORISTA', registro_profesional: '', especialidad_o_area: '' };
  }

  async cargar() {
    try {
      this.usuarios.set(await this.api.get<UsuarioAdmin[]>('/api/usuarios'));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async activar(u: UsuarioAdmin) {
    await this.ejecutar(() => this.api.patch(`/api/usuarios/${u.usuario_id}`, { activo: !u.activo }),
      `Usuario ${u.activo ? 'desactivado' : 'activado'}.`);
  }

  async asignar(u: UsuarioAdmin) {
    const rol = this.rolNuevo[u.usuario_id];
    await this.ejecutar(() => this.api.post(`/api/usuarios/${u.usuario_id}/roles`, {
      rol, registro_profesional: this.registro[u.usuario_id] || null, especialidad_o_area: this.area[u.usuario_id] || null,
    }), `Rol ${this.nombre(rol)} agregado a ${u.nombre}.`);
    this.rolNuevo[u.usuario_id] = '';
  }

  async crear() {
    await this.ejecutar(async () => {
      await this.api.post('/api/usuarios', { ...this.n, telefono: this.n.telefono || null,
        registro_profesional: this.n.registro_profesional || null, especialidad_o_area: this.n.especialidad_o_area || null });
      this.n = this.vacio();
    }, 'Usuario creado.');
  }

  private async ejecutar(fn: () => Promise<unknown>, exito: string) {
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
