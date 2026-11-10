import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { Diagnostico, Regla, TipoExamen } from '../core/modelos';

interface CondicionNueva { parametro_id: number | null; operador: string; valor: number | null; valor2: number | null }

const SIMBOLO: Record<string, string> = { '<': '<', '<=': '≤', '>': '>', '>=': '≥' };

@Component({
  selector: 'app-conocimiento',
  imports: [FormsModule],
  template: `
    <h1>Base de conocimientos</h1>
    <p class="sub">Reglas que relacionan resultados de laboratorio con diagnósticos CIE-10. El motor las evalúa al registrar
      resultados y el médico acepta o descarta cada sugerencia; esas respuestas miden la precisión de cada regla.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

    <div class="card tabla-scroll">
      <h2>Reglas diagnósticas</h2>
      <table>
        <thead><tr><th>Regla</th><th>Si…</th><th>Sugiere</th><th>Confianza</th><th class="num">Precisión</th><th>Estado</th></tr></thead>
        <tbody>
          @for (r of reglas(); track r.regla_id) {
            <tr [class.inactiva]="!r.activa">
              <td><strong>{{ r.codigo }}</strong>
                @if (r.sexo) { <br /><small class="muted">solo {{ r.sexo === 'F' ? 'mujeres' : 'hombres' }}</small> }</td>
              <td>{{ textoCondiciones(r) }}</td>
              <td><strong>{{ r.codigo_cie10 }}</strong> {{ r.diagnostico }}<br /><small class="muted">{{ r.recomendacion }}</small></td>
              <td><span [class]="'badge ' + (r.confianza === 'ALTA' ? 'rojo' : r.confianza === 'MEDIA' ? 'ambar' : 'gris')">{{ r.confianza.toLowerCase() }}</span></td>
              <td class="num">
                @if (r.precision_pct !== null) { <strong>{{ r.precision_pct }} %</strong> } @else { — }
                <br /><small class="muted">{{ r.aceptadas }} ✓ / {{ r.descartadas }} ✗ de {{ r.sugerencias }}</small>
              </td>
              <td>
                <span [class]="r.activa ? 'badge' : 'badge gris'">{{ r.activa ? 'activa' : 'inactiva' }}</span>
                @if (auth.tiene('ADMIN')) {
                  <br /><button class="secundario chico" (click)="alternar(r)">{{ r.activa ? 'Desactivar' : 'Activar' }}</button>
                }
              </td>
            </tr>
          }
        </tbody>
      </table>
    </div>

    <div class="card tabla-scroll">
      <h2>Diagnósticos y protocolos</h2>
      <table>
        <thead><tr><th>CIE-10</th><th>Diagnóstico</th><th>Protocolo sugerido</th></tr></thead>
        <tbody>
          @for (d of diagnosticos(); track d.diagnostico_id) {
            <tr><td><strong>{{ d.codigo_cie10 }}</strong></td><td>{{ d.nombre }}<br /><small class="muted">{{ d.descripcion }}</small></td>
              <td>{{ d.protocolo }} @if (d.duracion_dias) { <small class="muted">({{ d.duracion_dias }} días)</small> }</td></tr>
          }
        </tbody>
      </table>
    </div>

    @if (auth.tiene('ADMIN')) {
      <form class="card" (ngSubmit)="guardar()">
        <h2>Nueva regla (o reemplazar una existente con el mismo código)</h2>
        <div class="fila">
          <div class="campo"><label>Código</label><input name="c" [(ngModel)]="n.codigo" placeholder="R-..." required /></div>
          <div class="campo" style="flex: 2"><label>Diagnóstico</label>
            <select name="d" [(ngModel)]="n.diagnostico_id" required>
              @for (d of diagnosticos(); track d.diagnostico_id) { <option [ngValue]="d.diagnostico_id">{{ d.codigo_cie10 }} · {{ d.nombre }}</option> }
            </select></div>
        </div>
        <div class="fila">
          <div class="campo"><label>Se cumple si</label><select name="l" [(ngModel)]="n.logica">
            <option value="TODAS">todas las condiciones</option><option value="ALGUNA">alguna condición</option></select></div>
          <div class="campo"><label>Confianza</label><select name="cf" [(ngModel)]="n.confianza">
            <option value="BAJA">baja</option><option value="MEDIA">media</option><option value="ALTA">alta</option></select></div>
          <div class="campo"><label>Sexo</label><select name="s" [(ngModel)]="n.sexo">
            <option value="">cualquiera</option><option value="F">mujeres</option><option value="M">hombres</option></select></div>
        </div>
        <h3>Condiciones</h3>
        @for (c of n.condiciones; track $index) {
          <div class="fila mini">
            <select [name]="'p' + $index" [(ngModel)]="c.parametro_id">
              @for (p of parametros(); track p.parametro_id) { <option [ngValue]="p.parametro_id">{{ p.nombre }}</option> }
            </select>
            <select [name]="'o' + $index" [(ngModel)]="c.operador">
              <option value="<">&lt;</option><option value="<=">≤</option><option value=">">&gt;</option><option value=">=">≥</option><option value="ENTRE">entre</option>
            </select>
            <input type="number" step="any" [name]="'v' + $index" [(ngModel)]="c.valor" placeholder="valor" />
            @if (c.operador === 'ENTRE') { <input type="number" step="any" [name]="'v2' + $index" [(ngModel)]="c.valor2" placeholder="hasta" /> }
            <button type="button" class="secundario chico" (click)="n.condiciones.splice($index, 1)">Quitar</button>
          </div>
        }
        <button type="button" class="secundario chico" (click)="n.condiciones.push(condicion())">+ Condición</button>
        <div class="campo"><label>Recomendación al médico</label><input name="r" [(ngModel)]="n.recomendacion" required /></div>
        <div class="fila">
          <div class="campo"><label>Fuente</label><input name="f" [(ngModel)]="n.fuente" /></div>
          <div class="campo"><label>Guía clínica (clave en MongoDB)</label><input name="g" [(ngModel)]="n.guia_clave" placeholder="diabetes, anemia…" /></div>
        </div>
        <button type="submit">Guardar regla</button>
      </form>
    }
  `,
  styles: `tr.inactiva td { opacity: .55; } .mini select, .mini input { flex: 1 1 110px; } h3 { margin-top: 12px; }`,
})
export class Conocimiento implements OnInit {
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly reglas = signal<Regla[]>([]);
  protected readonly diagnosticos = signal<Diagnostico[]>([]);
  protected readonly parametros = signal<{ parametro_id: number; nombre: string }[]>([]);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected n = this.vacia();

  async ngOnInit() {
    await this.cargar();
    if (this.auth.tiene('ADMIN')) {
      const catalogo = await this.api.get<TipoExamen[]>('/api/examenes/catalogo');
      this.parametros.set(catalogo.flatMap((t) => t.parametros.map((p) => ({ parametro_id: p.parametro_id, nombre: `${p.nombre} (${t.codigo})` }))));
    }
  }

  protected condicion(): CondicionNueva {
    return { parametro_id: null, operador: '>', valor: null, valor2: null };
  }

  private vacia() {
    return { codigo: '', diagnostico_id: null as number | null, logica: 'TODAS', confianza: 'MEDIA', sexo: '', recomendacion: '',
      fuente: '', guia_clave: '', condiciones: [this.condicion()] };
  }

  protected textoCondiciones(r: Regla): string {
    const partes = r.condiciones.map((c) => c.operador === 'ENTRE'
      ? `${c.parametro} entre ${+c.valor} y ${+(c.valor2 ?? 0)}`
      : `${c.parametro} ${SIMBOLO[c.operador]} ${+c.valor} ${c.unidad ?? ''}`.trim());
    return partes.join(r.logica === 'TODAS' ? ' y ' : ' o ');
  }

  async cargar() {
    try {
      const [r, d] = await Promise.all([
        this.api.get<Regla[]>('/api/conocimiento/reglas'),
        this.api.get<Diagnostico[]>('/api/conocimiento/diagnosticos'),
      ]);
      this.reglas.set(r);
      this.diagnosticos.set(d);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async alternar(r: Regla) {
    await this.ejecutar(() => this.api.patch(`/api/conocimiento/reglas/${r.regla_id}`, { activa: !r.activa }),
      `Regla ${r.codigo} ${r.activa ? 'desactivada' : 'activada'}.`);
  }

  async guardar() {
    const condiciones = this.n.condiciones
      .filter((c) => c.parametro_id && c.valor !== null)
      .map((c) => ({ parametro_id: c.parametro_id, operador: c.operador, valor: c.valor,
        ...(c.operador === 'ENTRE' ? { valor2: c.valor2 } : {}) }));
    await this.ejecutar(async () => {
      await this.api.post('/api/conocimiento/reglas', { ...this.n, sexo: this.n.sexo || null, fuente: this.n.fuente || null,
        guia_clave: this.n.guia_clave || null, condiciones });
      this.n = this.vacia();
    }, 'Regla guardada.');
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
