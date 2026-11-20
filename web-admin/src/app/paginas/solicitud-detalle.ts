import { Component, inject, input, OnDestroy, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { ActivatedRoute, RouterLink } from '@angular/router';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { claseEstado, dinero, fechaHora, rango, textoEstado } from '../core/formato';
import { DocumentoExterno, ExamenSolicitado, Parametro, Solicitud, TipoExamen } from '../core/modelos';
import { RecetaPanel } from './receta';
import { Sugerencias } from './sugerencias';

/** Valor que el laboratorista escribe por parámetro (número o texto cualitativo). */
interface Captura { parametro: Parametro; valor: string }

@Component({
  selector: 'app-solicitud-detalle',
  imports: [FormsModule, RouterLink, Sugerencias, RecetaPanel],
  template: `
    <!-- Si se abrió desde una consulta, vuelve a ella para terminarla. -->
    <button type="button" class="secundario chico" [routerLink]="volver()">&larr; {{ volver() === '/solicitudes' ? 'Volver a solicitudes' : 'Volver a la consulta' }}</button>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }
    @if (s(); as s) {
      <div class="entre cabeza">
        <div>
          <h1>{{ s.codigo }} <span [class]="claseEstado(s.estado)">{{ textoEstado(s.estado) }}</span></h1>
          <p class="sub">{{ s.paciente }} · CI {{ s.cedula }} · {{ fechaHora(s.created_at) }}
            @if (s.medico_id) { · Ordenado por {{ s.medico }} }</p>
          <p class="cobro">Subtotal {{ dinero(s.subtotal) }} · IVA {{ s.iva_porcentaje }} % {{ dinero(s.iva) }} ·
            <strong>Total {{ dinero(s.total) }}</strong></p>
        </div>
        <div class="fila">
          @if (tieneResultados()) {
            <button class="secundario" (click)="pdf()">Resultados (PDF)</button>
          }
          @if ((auth.tiene('ADMIN') || (auth.tiene('LABORATORISTA') && s.cobro_ventanilla)) && ['PAGADA', 'EN_PROCESO', 'COMPLETADA'].includes(s.estado)) {
            <button class="secundario" (click)="factura('pdf')">Factura (PDF)</button>
            <button class="secundario" (click)="factura('xml')">Factura (XML)</button>
          }
        </div>
      </div>
      @if (s.laboratorio_propio === false) {
        <div class="card externo">
          <h2>Exámenes en {{ s.laboratorio }}</h2>
          <p class="muted">Laboratorio externo: se pagan allá y el resultado se sube en PDF. El sistema lee los valores;
            el laboratorista los revisa y los registra, y desde ahí el médico los ve como cualquier resultado.</p>
          <div class="fila">
            <label class="boton-archivo secundario">Subir resultado (PDF)
              <input type="file" accept="application/pdf" (change)="subirPdf($event)" hidden /></label>
            @if (subiendo()) { <small class="muted">Subiendo y leyendo el PDF…</small> }
          </div>
          @for (d of documentos(); track d.documento_id) {
            <div class="doc">
              <button type="button" class="secundario chico" (click)="verPdf(d)">Ver {{ d.nombre_archivo }}</button>
              <small class="muted">{{ fechaHora(d.fecha) }} · {{ d.valores_leidos.length }} valores leídos</small>
              @if (d.valores_leidos.length) {
                <table class="leidos">
                  @for (v of d.valores_leidos; track v.parametro_id) { <tr><td>{{ v.parametro }}</td><td><strong>{{ v.valor ?? v.texto }}</strong></td></tr> }
                </table>
                @if (auth.tiene('LABORATORISTA') && puedeProcesar()) {
                  <button type="button" class="chico" (click)="usarValores(d)">Llenar los resultados con estos valores</button>
                }
              } @else if (!d.texto_leido) { <small class="muted"> · el PDF no tiene texto (escaneado): transcriba los valores.</small> }
            </div>
          } @empty { <p class="muted">Todavía no se ha subido el resultado.</p> }
        </div>
      } @else if (s.estado === 'REGISTRADA') {
        <div class="alerta aviso">La solicitud aún no está pagada: no se pueden registrar muestras ni resultados.</div>
        @if (auth.tiene('LABORATORISTA', 'ADMIN')) {
          <div class="card cobro-ventanilla">
            <h2>Cobrar en ventanilla</h2>
            <p class="muted">El cobro pasa por la pasarela (Stripe). Tome los datos para la factura; el paciente paga con el QR en su
              celular o aquí mismo. Al confirmarse el pago, la factura sale con estos datos.</p>
            @if (!cobro()) {
              <label class="check"><input type="checkbox" [(ngModel)]="consumidorFinal" /> Consumidor final (sin datos)</label>
              @if (!consumidorFinal) {
                <div class="fila">
                  <div class="campo"><label for="fi">Cédula o RUC</label><input id="fi" [(ngModel)]="fact.identificacion" maxlength="13" /></div>
                  <div class="campo"><label for="fn">Nombre o razón social</label><input id="fn" maxlength="200" [(ngModel)]="fact.nombre" /></div>
                </div>
                <div class="fila">
                  <div class="campo"><label for="fd">Dirección</label><input id="fd" maxlength="250" [(ngModel)]="fact.direccion" /></div>
                </div>
              }
              <div class="fila">
                <div class="campo"><label for="fe">Correo para la factura (opcional)</label><input id="fe" type="email" maxlength="150" [(ngModel)]="fact.email" /></div>
              </div>
              <button (click)="cobrar()" [disabled]="guardando() || (!consumidorFinal && (!fact.identificacion || !fact.nombre))">
                Generar cobro de {{ dinero(s.total) }}</button>
            } @else {
              <div class="qr">
                <img [src]="cobro()!.qr" alt="Código QR para pagar con Stripe" width="200" height="200" />
                <div>
                  <p><strong>{{ dinero(cobro()!.monto) }}</strong>. Escanee con la cámara del celular para pagar con tarjeta.</p>
                  <a class="boton" [href]="cobro()!.checkout_url" target="_blank" rel="noopener">Abrir el pago en esta pantalla</a>
                  <p class="muted">Esperando la confirmación de Stripe… se actualiza sola.</p>
                  <button class="secundario chico" (click)="cancelarCobro()">Generar otro cobro</button>
                </div>
              </div>
            }
          </div>
        }
      }
      @if (tieneResultados()) {
        <!-- Se recrea cuando cambia el número de resultados: re-lee las sugerencias. -->
        @for (k of [cantidadResultados()]; track k) {
          <app-sugerencias [solicitudId]="s.solicitud_id" [pacienteId]="s.paciente_id" />
        }
      }

      @for (ex of s.examenes; track ex.detalle_id) {
        <div class="card">
          <div class="entre">
            <h2>{{ ex.examen }} <small class="muted">{{ ex.codigo }}</small></h2>
            <span [class]="claseEstado(ex.estado)">{{ textoEstado(ex.estado) }}</span>
          </div>

          @if (ex.resultado_id) {
            <div class="tabla-scroll">
              <table>
                <thead><tr><th>Parámetro</th><th class="num">Resultado</th><th>Unidad</th><th>Referencia</th><th>Indicador</th></tr></thead>
                <tbody>
                  @for (v of ex.valores; track v.parametro_id) {
                    <tr>
                      <td>{{ v.parametro }}</td>
                      <td class="num" [class.fuera]="v.fuera_rango">{{ v.valor_texto ?? v.valor_numerico }}</td>
                      <td>{{ v.unidad }}</td><td>{{ rango(v.valor_ref_min, v.valor_ref_max, v.valor_ref_texto) }}</td>
                      <td [class.fuera]="v.fuera_rango" class="indicador">{{ indicador(v.nivel) }}</td>
                    </tr>
                  }
                </tbody>
              </table>
            </div>
            <p class="muted">Registrado por {{ ex.laboratorista }} el {{ fechaHora(ex.fecha_resultado) }}.
              @if (ex.observaciones_laboratorio) { Nota: {{ ex.observaciones_laboratorio }} }</p>
            @for (o of ex.observaciones_medicas; track o.observacion_id) {
              <div class="obs"><strong>{{ o.medico }}</strong> <small class="muted">{{ fechaHora(o.created_at) }}</small><br />{{ o.texto }}</div>
            }
            @if (auth.tiene('MEDICO')) {
              <form class="fila" (ngSubmit)="observar(ex)">
                <div class="campo"><label>Nueva observación médica</label>
                  <textarea [name]="'obs' + ex.detalle_id" maxlength="2000" [(ngModel)]="observacion[ex.detalle_id]"></textarea></div>
                <div class="campo"><button type="submit" [disabled]="!observacion[ex.detalle_id]?.trim()">Guardar observación</button></div>
              </form>
            }
          } @else if (auth.tiene('LABORATORISTA') && puedeProcesar()) {
            @if (ex.estado === 'PENDIENTE' && s.laboratorio_propio !== false) {
              <p class="muted">Primero registre la toma de muestra.</p>
              <button class="secundario" (click)="muestra(ex)">Registrar toma de muestra</button>
            } @else if (capturas[ex.detalle_id]) {
              <form (ngSubmit)="guardarResultado(ex)">
                <div class="tabla-scroll">
                  <table>
                    <thead><tr><th>Parámetro</th><th>Valor</th><th>Unidad</th><th>Referencia</th></tr></thead>
                    <tbody>
                      @for (c of capturas[ex.detalle_id]; track c.parametro.parametro_id) {
                        <tr>
                          <td>{{ c.parametro.nombre }}</td>
                          <td><input [name]="'v' + c.parametro.parametro_id" maxlength="200" [(ngModel)]="c.valor" required
                                     [placeholder]="c.parametro.valor_ref_texto ? 'texto' : 'número'" /></td>
                          <td>{{ c.parametro.unidad }}</td>
                          <td>{{ rango(c.parametro.valor_ref_min, c.parametro.valor_ref_max, c.parametro.valor_ref_texto) }}</td>
                        </tr>
                      }
                    </tbody>
                  </table>
                </div>
                <div class="campo"><label>Observaciones del laboratorio</label>
                  <textarea [name]="'nota' + ex.detalle_id" maxlength="1000" [(ngModel)]="notas[ex.detalle_id]"></textarea></div>
                <button type="submit" [disabled]="guardando()">Guardar resultado</button>
              </form>
            }
          } @else {
            <p class="muted">Resultado pendiente.</p>
          }
        </div>
      }

      <!-- Receta: el médico la escribe con la propuesta de la base de conocimientos; los demás la consultan. -->
      @if (auth.tiene('MEDICO') && tieneResultados() && ['EN_PROCESO', 'COMPLETADA'].includes(s.estado)) {
        @for (k of [cantidadResultados()]; track k) {
          <app-receta [solicitudId]="s.solicitud_id" />
        }
      }
    } @else if (!error()) {
      <p class="muted">Cargando…</p>
    }
  `,
  styles: `
    .cabeza { margin-top: 12px; }
    h1 .badge { vertical-align: middle; margin-left: 8px; }
    .obs { background: var(--azul-suave); border-radius: 6px; padding: 8px 12px; margin: 8px 0; }
    .cobro { margin: -12px 0 16px; color: var(--gris); }
    .externo { border-left: 4px solid var(--ambar); border-radius: 0; }
    .boton-archivo { display: inline-block; padding: 8px 14px; border: 1px solid var(--verde); border-radius: 6px; cursor: pointer; color: var(--verde); }
    .doc { border-top: 1px solid var(--borde); padding: 8px 0; }
    .leidos td { padding: 2px 10px 2px 0; }
    .cobro-ventanilla .check { display: flex; gap: 8px; align-items: center; margin-bottom: 8px; }
    .qr { display: flex; gap: 20px; align-items: center; flex-wrap: wrap; }
    .qr img { border: 1px solid var(--borde); border-radius: 6px; background: #fff; }
    a.boton { display: inline-block; background: var(--verde); color: #fff; padding: 8px 14px; border-radius: 6px; text-decoration: none; }
    .indicador { white-space: nowrap; font-weight: 600; }
  `,
})
export class SolicitudDetalle implements OnInit, OnDestroy {
  readonly id = input.required<string>();
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly claseEstado = claseEstado;
  protected readonly textoEstado = textoEstado;
  protected readonly fechaHora = fechaHora;
  protected readonly dinero = dinero;
  protected readonly rango = rango;
  protected readonly s = signal<Solicitud | null>(null);
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected readonly guardando = signal(false);
  private readonly ruta = inject(ActivatedRoute);
  protected readonly volver = signal(this.destinoVolver());
  /** Cobro en ventanilla: URL de Stripe Checkout y su QR mientras se espera la confirmación. */
  protected readonly cobro = signal<{ pago_id: number; checkout_url: string; qr: string; monto: number } | null>(null);
  protected consumidorFinal = false;
  protected fact = { identificacion: '', nombre: '', direccion: '', email: '' };
  private espera?: ReturnType<typeof setInterval>;

  ngOnDestroy() {
    clearInterval(this.espera);
  }

  /** Solo se acepta volver a una consulta del propio sistema; si no, a la lista de solicitudes. */
  private destinoVolver(): string {
    const v = this.ruta.snapshot.queryParamMap.get('volver') ?? '';
    return /^\/consulta\/\d+$/.test(v) ? v : '/solicitudes';
  }

  async cobrar() {
    this.error.set('');
    this.guardando.set(true);
    try {
      const f = this.consumidorFinal ? { email: this.fact.email || null } : { ...this.fact, direccion: this.fact.direccion || null,
        email: this.fact.email || null };
      this.cobro.set(await this.api.post('/api/pagos/ventanilla', { solicitud_id: Number(this.id()), factura: f }));
      // Se consulta cada 4 s hasta que el webhook de Stripe confirme el pago.
      clearInterval(this.espera);
      this.espera = setInterval(async () => {
        const s = await this.api.get<Solicitud>(`/api/solicitudes/${this.id()}`).catch(() => null);
        if (s && s.estado !== 'REGISTRADA') {
          clearInterval(this.espera);
          this.cobro.set(null);
          await this.cargar(s);
          this.aviso.set('Pago confirmado por Stripe. Ya puede tomar las muestras; la factura está lista.');
        }
      }, 4000);
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.guardando.set(false);
    }
  }

  cancelarCobro() {
    clearInterval(this.espera);
    this.cobro.set(null);
  }
  protected capturas: Record<number, Captura[]> = {};
  protected notas: Record<number, string> = {};
  protected observacion: Record<number, string> = {};
  private catalogo: TipoExamen[] = [];

  async ngOnInit() {
    try {
      // Catálogo y solicitud se piden en paralelo.
      const [catalogo, solicitud] = await Promise.all([
        this.api.get<TipoExamen[]>('/api/examenes/catalogo'),
        this.api.get<Solicitud>(`/api/solicitudes/${this.id()}`),
      ]);
      this.catalogo = catalogo;
      await this.cargar(solicitud);
      await this.cargarDocumentos();
      // Datos de facturación propuestos: los del paciente (se pueden cambiar).
      this.fact = { identificacion: solicitud.cedula, nombre: solicitud.paciente, direccion: '', email: '' };
      const pago = this.ruta.snapshot.queryParamMap.get('pago');
      if (pago === 'exito') this.aviso.set('Stripe recibió el pago. La solicitud se marca como pagada en cuanto llega su confirmación.');
      if (pago === 'cancelado') this.error.set('El pago se canceló en Stripe. Puede generar otro cobro.');
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  private async cargar(previa?: Solicitud) {
    const s = previa ?? (await this.api.get<Solicitud>(`/api/solicitudes/${this.id()}`));
    for (const ex of s.examenes) {
      if (!ex.resultado_id && !this.capturas[ex.detalle_id]) {
        const tipo = this.catalogo.find((t) => t.tipo_examen_id === ex.tipo_examen_id);
        this.capturas[ex.detalle_id] = (tipo?.parametros ?? []).map((p) => ({ parametro: p, valor: '' }));
      }
    }
    this.s.set(s);
  }

  protected puedeProcesar(): boolean {
    // El cobro de una consulta médica no lleva muestras ni resultados. Un laboratorio externo no se paga aquí.
    const s = this.s();
    if (!s || s.tipo === 'CONSULTA') return false;
    return ['PAGADA', 'EN_PROCESO'].includes(s.estado) || (s.laboratorio_propio === false && s.estado === 'REGISTRADA');
  }

  protected readonly documentos = signal<DocumentoExterno[]>([]);
  protected readonly subiendo = signal(false);

  private async cargarDocumentos() {
    if (this.s()?.laboratorio_propio !== false) return;
    try {
      this.documentos.set(await this.api.get<DocumentoExterno[]>(`/api/solicitudes/${this.id()}/resultado-externo`));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async subirPdf(ev: Event) {
    const input = ev.target as HTMLInputElement;
    const archivo = input.files?.[0];
    input.value = '';
    if (!archivo) return;
    if (archivo.size > 5 * 1024 * 1024) {
      this.error.set('El PDF no puede pasar de 5 MB.');
      return;
    }
    this.subiendo.set(true);
    this.error.set('');
    try {
      const datos = new Uint8Array(await archivo.arrayBuffer());
      let binario = '';
      for (let i = 0; i < datos.length; i += 0x8000) binario += String.fromCharCode(...datos.subarray(i, i + 0x8000));
      const r = await this.api.post<{ valores: unknown[] }>(`/api/solicitudes/${this.id()}/resultado-externo`,
        { nombre: archivo.name.slice(0, 150), contenido_base64: btoa(binario) });
      this.aviso.set(r.valores.length ? `PDF subido: se leyeron ${r.valores.length} valores.` : 'PDF subido; no se pudieron leer valores.');
      await this.cargarDocumentos();
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.subiendo.set(false);
    }
  }

  async verPdf(d: DocumentoExterno) {
    try {
      await this.api.abrirArchivo(`/api/solicitudes/${this.id()}/resultado-externo/${d.documento_id}`);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  /** Lleva los valores leídos del PDF a los formularios de captura; el laboratorista revisa y guarda. */
  usarValores(d: DocumentoExterno) {
    for (const v of d.valores_leidos) {
      const c = this.capturas[v.detalle_id]?.find((x) => x.parametro.parametro_id === v.parametro_id);
      if (c) c.valor = String(v.valor ?? v.texto ?? '');
    }
    this.aviso.set('Valores cargados en los formularios: revíselos y guarde cada resultado.');
  }


  protected cantidadResultados(): number {
    return this.s()?.examenes.filter((e) => e.resultado_id).length ?? 0;
  }

  protected tieneResultados(): boolean {
    return !!this.s()?.examenes.some((e) => e.resultado_id);
  }

  async muestra(ex: ExamenSolicitado) {
    await this.accion(() => this.api.post(`/api/solicitudes/detalle/${ex.detalle_id}/muestra`), 'Toma de muestra registrada.');
  }

  async guardarResultado(ex: ExamenSolicitado) {
    const valores = (this.capturas[ex.detalle_id] ?? []).map((c) => {
      const num = Number(c.valor.replace(',', '.'));
      return c.parametro.valor_ref_texto || Number.isNaN(num)
        ? { parametro_id: c.parametro.parametro_id, texto: c.valor.trim() }
        : { parametro_id: c.parametro.parametro_id, valor: num };
    });
    this.guardando.set(true);
    await this.accion(() => this.api.post('/api/resultados', {
      detalle_id: ex.detalle_id, valores, observaciones: this.notas[ex.detalle_id] || null,
    }), `Resultado de ${ex.examen} registrado.`);
    this.guardando.set(false);
  }

  async observar(ex: ExamenSolicitado) {
    await this.accion(() => this.api.post('/api/observaciones', {
      resultado_id: ex.resultado_id, texto: this.observacion[ex.detalle_id].trim(),
    }), 'Observación registrada.');
    this.observacion[ex.detalle_id] = '';
  }

  protected indicador(nivel?: string): string {
    return { ALTO: '↑ alto', BAJO: '↓ bajo', ANORMAL: 'fuera de rango' }[nivel ?? ''] ?? '– normal';
  }

  async factura(formato: 'pdf' | 'xml') {
    try {
      await this.api.abrirArchivo(`/api/pagos/factura/${this.id()}?formato=${formato}`,
        formato === 'xml' ? `factura-${this.s()?.codigo}.xml` : undefined);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  async pdf() {
    try {
      await this.api.abrirArchivo(`/api/solicitudes/${this.id()}/pdf`);
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  private async accion(fn: () => Promise<unknown>, exito: string) {
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
