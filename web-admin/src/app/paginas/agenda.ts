import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, hora, hoyIso, textoEstado } from '../core/formato';
import { Cita } from '../core/modelos';
import { paginarLocal, Paginador } from '../core/paginador';

@Component({
  selector: 'app-agenda',
  imports: [FormsModule, Paginador],
  template: `
    <div class="entre">
      <div><h1>Agenda del día</h1>
        <p class="sub">Turnos de toma de muestras en el laboratorio. Una cita queda <strong>confirmada</strong> cuando el paciente
          paga los exámenes vinculados a ella; si no paga en 30 minutos, se cancela sola y el cupo se libera.</p></div>
      <div class="fila">
        <div class="campo"><label for="f">Fecha</label>
          <input id="f" type="date" [(ngModel)]="fecha" (change)="cargar()" /></div>
      </div>
    </div>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    <div class="card tabla-scroll">
      <div class="buscador"><input type="search" placeholder="Buscar por paciente, cédula, solicitud o examen" [ngModel]="q()" (ngModelChange)="q.set($event); pag.set(1)" /></div>
      <table>
        <thead><tr><th>Hora</th><th>Paciente</th><th>Cédula</th><th>Exámenes</th><th>Motivo</th><th>Estado</th><th></th></tr></thead>
        <tbody>
          @for (c of vista().items; track c.cita_id) {
            <tr>
              <td><strong>{{ hora(c.hora_inicio) }}</strong>–{{ hora(c.hora_fin) }}</td>
              <td>{{ c.paciente }}</td><td>{{ c.cedula }}</td>
              <td>@if (c.solicitud_id) { <strong>{{ c.solicitud_codigo }}</strong><br /><small>{{ c.examenes_resumen }}</small> }
                @else { <small class="muted">Aún no elige exámenes</small> }</td>
              <td>{{ c.motivo }}</td>
              <td><span [class]="claseEstado(c.estado)">{{ textoEstado(c.estado) }}</span></td>
              <td class="acciones">
                @if (c.solicitud_id) {
                  <button class="chico" (click)="abrir(c.solicitud_id)">Abrir solicitud</button>
                }
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
      <app-paginador [pagina]="vista()" (cambiar)="pag.set($event)" />
    </div>
  `,
  styles: `.acciones { white-space: nowrap; } .acciones button { margin: 2px; }`,
})
export class Agenda implements OnInit {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  protected readonly auth = inject(AuthService);
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly hora = hora;
  protected fecha = hoyIso();
  protected readonly citas = signal<Cita[]>([]);
  protected readonly q = signal('');
  protected readonly pag = signal(1);
  protected readonly vista = computed(() => paginarLocal(this.citas(), this.pag(), this.q(),
    (c) => `${c.paciente} ${c.cedula} ${c.solicitud_codigo ?? ''} ${c.examenes_resumen ?? ''} ${c.motivo ?? ''}`));
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

  abrir(solicitudId: number) {
    this.router.navigate(['/solicitudes', solicitudId]);
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
