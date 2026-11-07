import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, hora, hoyIso, textoEstado } from '../core/formato';
import { Cita } from '../core/modelos';

@Component({
  selector: 'app-agenda',
  imports: [FormsModule],
  template: `
    <div class="entre">
      <div><h1>Agenda del día</h1><p class="sub">Citas reservadas por los pacientes.</p></div>
      <div class="fila">
        <div class="campo"><label for="f">Fecha</label>
          <input id="f" type="date" [(ngModel)]="fecha" (change)="cargar()" /></div>
      </div>
    </div>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    <div class="card tabla-scroll">
      <table>
        <thead><tr><th>Hora</th><th>Paciente</th><th>Cédula</th><th>Motivo</th><th>Canal</th><th>Estado</th><th></th></tr></thead>
        <tbody>
          @for (c of citas(); track c.cita_id) {
            <tr>
              <td><strong>{{ hora(c.hora_inicio) }}</strong>–{{ hora(c.hora_fin) }}</td>
              <td>{{ c.paciente }}</td><td>{{ c.cedula }}</td><td>{{ c.motivo }}</td>
              <td>{{ c.canal }}</td>
              <td><span [class]="claseEstado(c.estado)">{{ textoEstado(c.estado) }}</span></td>
              <td>
                @if (auth.tiene('ADMIN') && (c.estado === 'PENDIENTE_PAGO' || c.estado === 'CONFIRMADA')) {
                  <button class="secundario chico" (click)="cancelar(c)">Cancelar</button>
                }
              </td>
            </tr>
          } @empty {
            <tr><td colspan="7" class="vacio">{{ cargando() ? 'Cargando…' : 'No hay citas para esta fecha.' }}</td></tr>
          }
        </tbody>
      </table>
    </div>
  `,
})
export class Agenda implements OnInit {
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly hora = hora;
  protected fecha = hoyIso();
  protected readonly citas = signal<Cita[]>([]);
  protected readonly cargando = signal(false);
  protected readonly error = signal('');
  protected readonly aviso = signal('');

  ngOnInit() {
    this.cargar();
  }

  async cargar() {
    this.cargando.set(true);
    this.error.set('');
    try {
      this.citas.set(await this.api.get<Cita[]>('/api/citas/agenda', { fecha: this.fecha }));
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.cargando.set(false);
    }
  }

  async cancelar(c: Cita) {
    if (!confirm(`¿Cancelar la cita de ${c.paciente} a las ${hora(c.hora_inicio)}? El cupo quedará libre.`)) return;
    try {
      await this.api.delete(`/api/citas/${c.cita_id}`);
      this.aviso.set('Cita cancelada.');
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
