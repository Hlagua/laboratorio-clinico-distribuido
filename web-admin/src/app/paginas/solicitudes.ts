import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, dinero, fechaHora, textoEstado } from '../core/formato';
import { SolicitudResumen } from '../core/modelos';

@Component({
  selector: 'app-solicitudes',
  imports: [FormsModule],
  template: `
    <h1>Solicitudes y resultados</h1>
    <p class="sub">Órdenes de exámenes. Abra una para registrar muestras, resultados u observaciones.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    <form class="card fila" (ngSubmit)="buscar()">
      <div class="campo"><label for="e">Estado</label>
        <select id="e" name="estado" [(ngModel)]="estado">
          <option value="">Todos</option>
          @for (e of estados; track e) { <option [value]="e">{{ textoEstado(e) }}</option> }
        </select></div>
      <div class="campo"><label for="c">Cédula del paciente</label>
        <input id="c" name="cedula" [(ngModel)]="cedula" maxlength="10" /></div>
      <div class="campo"><label for="o">Código</label>
        <input id="o" name="codigo" [(ngModel)]="codigo" placeholder="SOL-2026-000001" /></div>
      @if (auth.tiene('MEDICO')) {
        <label class="check"><input type="checkbox" name="propias" [(ngModel)]="propias" /> Solo las que ordené</label>
      }
      <div class="campo"><button type="submit">Buscar</button></div>
    </form>
    <div class="card tabla-scroll">
      <table>
        <thead><tr><th>Código</th><th>Paciente</th><th>Cédula</th><th>Médico</th><th>Fecha</th><th class="num">Total</th><th>Estado</th></tr></thead>
        <tbody>
          @for (s of lista(); track s.solicitud_id) {
            <tr class="clic" (click)="abrir(s)">
              <td><strong>{{ s.codigo }}</strong></td><td>{{ s.paciente }}</td><td>{{ s.cedula }}</td>
              <td>{{ s.medico_id ? s.medico : '—' }}</td><td>{{ fechaHora(s.created_at) }}</td>
              <td class="num">{{ dinero(s.total) }}</td>
              <td><span [class]="claseEstado(s.estado)">{{ textoEstado(s.estado) }}</span></td>
            </tr>
          } @empty {
            <tr><td colspan="7" class="vacio">{{ cargando() ? 'Cargando…' : 'Sin resultados.' }}</td></tr>
          }
        </tbody>
      </table>
    </div>
  `,
  styles: `.check { display: flex; gap: 6px; align-items: center; margin-bottom: 18px; }`,
})
export class Solicitudes implements OnInit {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  protected readonly auth = inject(AuthService);
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly dinero = dinero;
  protected readonly fechaHora = fechaHora;
  protected readonly estados = ['REGISTRADA', 'PAGADA', 'EN_PROCESO', 'COMPLETADA', 'ANULADA'];
  protected estado = '';
  protected cedula = '';
  protected codigo = '';
  protected propias = false;
  protected readonly lista = signal<SolicitudResumen[]>([]);
  protected readonly cargando = signal(false);
  protected readonly error = signal('');

  ngOnInit() {
    this.estado = this.auth.tiene('LABORATORISTA') ? 'PAGADA' : '';
    this.buscar();
  }

  async buscar() {
    this.cargando.set(true);
    this.error.set('');
    try {
      this.lista.set(await this.api.get<SolicitudResumen[]>('/api/solicitudes', {
        estado: this.estado, cedula: this.cedula.trim(), codigo: this.codigo.trim(), propias: this.propias ? 1 : null,
      }));
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.cargando.set(false);
    }
  }

  abrir(s: SolicitudResumen) {
    this.router.navigate(['/solicitudes', s.solicitud_id]);
  }
}
