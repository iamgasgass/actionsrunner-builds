package android.graphics;

/** A 3x3 transform, as Android keeps it: MSCALE_X, MSKEW_X, MTRANS_X / MSKEW_Y, MSCALE_Y, MTRANS_Y / MPERSP_0..2. */
public class Matrix {
    public static final int MSCALE_X = 0, MSKEW_X = 1, MTRANS_X = 2, MSKEW_Y = 3, MSCALE_Y = 4, MTRANS_Y = 5, MPERSP_0 = 6, MPERSP_1 = 7, MPERSP_2 = 8;
    public enum ScaleToFit { FILL, START, CENTER, END }
    public static final Matrix IDENTITY_MATRIX = new Matrix();

    final float[] m = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };

    public Matrix() {}
    public Matrix(Matrix src) { if (src != null) set(src); }

    public boolean isIdentity() { return m[0] == 1 && m[1] == 0 && m[2] == 0 && m[3] == 0 && m[4] == 1 && m[5] == 0 && m[6] == 0 && m[7] == 0 && m[8] == 1; }
    public boolean isAffine() { return m[6] == 0 && m[7] == 0 && m[8] == 1; }
    public boolean rectStaysRect() { return (m[1] == 0 && m[3] == 0) || (m[0] == 0 && m[4] == 0); }
    public void set(Matrix src) { if (src == null) reset(); else System.arraycopy(src.m, 0, m, 0, 9); }
    public void reset() { m[0] = 1; m[1] = 0; m[2] = 0; m[3] = 0; m[4] = 1; m[5] = 0; m[6] = 0; m[7] = 0; m[8] = 1; }
    public void getValues(float[] v) { System.arraycopy(m, 0, v, 0, 9); }
    public void setValues(float[] v) { System.arraycopy(v, 0, m, 0, 9); }
    /** The affine part, as husk.Gfx takes it. */
    public float[] huskAffine() { return new float[] { m[0], m[1], m[2], m[3], m[4], m[5] }; }
    /** The affine part into the caller's array (Canvas keeps one): the drawing path makes no garbage. */
    public void huskAffine(float[] out) { out[0] = m[0]; out[1] = m[1]; out[2] = m[2]; out[3] = m[3]; out[4] = m[4]; out[5] = m[5]; }

    /*
     * No allocation anywhere here: the view system concatenates a matrix per view per frame, and each operation used to make two
     * float[9] (the operand and the product), which the runtime keeps -- the largest share of float[] in long sessions.
     */
    private static void mul(float[] out, float[] a, float[] b) {
        float a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3], a4 = a[4], a5 = a[5], a6 = a[6], a7 = a[7], a8 = a[8];
        float b0 = b[0], b1 = b[1], b2 = b[2], b3 = b[3], b4 = b[4], b5 = b[5], b6 = b[6], b7 = b[7], b8 = b[8];
        out[0] = a0 * b0 + a1 * b3 + a2 * b6; out[1] = a0 * b1 + a1 * b4 + a2 * b7; out[2] = a0 * b2 + a1 * b5 + a2 * b8;
        out[3] = a3 * b0 + a4 * b3 + a5 * b6; out[4] = a3 * b1 + a4 * b4 + a5 * b7; out[5] = a3 * b2 + a4 * b5 + a5 * b8;
        out[6] = a6 * b0 + a7 * b3 + a8 * b6; out[7] = a6 * b1 + a7 * b4 + a8 * b7; out[8] = a6 * b2 + a7 * b5 + a8 * b8;
    }
    private void set9(float v0, float v1, float v2, float v3, float v4, float v5, float v6, float v7, float v8) {
        m[0] = v0; m[1] = v1; m[2] = v2; m[3] = v3; m[4] = v4; m[5] = v5; m[6] = v6; m[7] = v7; m[8] = v8;
    }
    /** this = this x B, for an affine B (b6, b7, b8 = 0, 0, 1) */
    private void preAff(float b0, float b1, float b2, float b3, float b4, float b5) {
        float a0 = m[0], a1 = m[1], a2 = m[2], a3 = m[3], a4 = m[4], a5 = m[5], a6 = m[6], a7 = m[7], a8 = m[8];
        set9(a0 * b0 + a1 * b3, a0 * b1 + a1 * b4, a0 * b2 + a1 * b5 + a2,
             a3 * b0 + a4 * b3, a3 * b1 + a4 * b4, a3 * b2 + a4 * b5 + a5,
             a6 * b0 + a7 * b3, a6 * b1 + a7 * b4, a6 * b2 + a7 * b5 + a8);
    }
    /** this = A x this, for an affine A */
    private void postAff(float a0, float a1, float a2, float a3, float a4, float a5) {
        float b0 = m[0], b1 = m[1], b2 = m[2], b3 = m[3], b4 = m[4], b5 = m[5], b6 = m[6], b7 = m[7], b8 = m[8];
        set9(a0 * b0 + a1 * b3 + a2 * b6, a0 * b1 + a1 * b4 + a2 * b7, a0 * b2 + a1 * b5 + a2 * b8,
             a3 * b0 + a4 * b3 + a5 * b6, a3 * b1 + a4 * b4 + a5 * b7, a3 * b2 + a4 * b5 + a5 * b8,
             b6, b7, b8);
    }

    public void setTranslate(float dx, float dy) { set9(1, 0, dx, 0, 1, dy, 0, 0, 1); }
    public void setScale(float sx, float sy, float px, float py) { set9(sx, 0, px - sx * px, 0, sy, py - sy * py, 0, 0, 1); }
    public void setScale(float sx, float sy) { setScale(sx, sy, 0, 0); }
    public void setRotate(float d, float px, float py) { double a = Math.toRadians(d); setSinCos((float) Math.sin(a), (float) Math.cos(a), px, py); }
    public void setRotate(float d) { setRotate(d, 0, 0); }
    public void setSinCos(float sin, float cos, float px, float py) { set9(cos, -sin, px - cos * px + sin * py, sin, cos, py - sin * px - cos * py, 0, 0, 1); }
    public void setSinCos(float sin, float cos) { setSinCos(sin, cos, 0, 0); }
    public void setSkew(float kx, float ky, float px, float py) { set9(1, kx, -kx * py, ky, 1, -ky * px, 0, 0, 1); }
    public void setSkew(float kx, float ky) { setSkew(kx, ky, 0, 0); }
    public boolean setConcat(Matrix a, Matrix b) { mul(m, a.m, b.m); return true; }
    public boolean preTranslate(float dx, float dy) { preAff(1, 0, dx, 0, 1, dy); return true; }
    public boolean preScale(float sx, float sy, float px, float py) { preAff(sx, 0, px - sx * px, 0, sy, py - sy * py); return true; }
    public boolean preScale(float sx, float sy) { return preScale(sx, sy, 0, 0); }
    public boolean preRotate(float d, float px, float py) {
        double a = Math.toRadians(d); float c = (float) Math.cos(a), sn = (float) Math.sin(a);
        preAff(c, -sn, px - c * px + sn * py, sn, c, py - sn * px - c * py); return true;
    }
    public boolean preRotate(float d) { return preRotate(d, 0, 0); }
    public boolean preSkew(float kx, float ky, float px, float py) { preAff(1, kx, -kx * py, ky, 1, -ky * px); return true; }
    public boolean preSkew(float kx, float ky) { return preSkew(kx, ky, 0, 0); }
    public boolean preConcat(Matrix o) { mul(m, m, o.m); return true; }
    public boolean postTranslate(float dx, float dy) { postAff(1, 0, dx, 0, 1, dy); return true; }
    public boolean postScale(float sx, float sy, float px, float py) { postAff(sx, 0, px - sx * px, 0, sy, py - sy * py); return true; }
    public boolean postScale(float sx, float sy) { return postScale(sx, sy, 0, 0); }
    public boolean postRotate(float d, float px, float py) {
        double a = Math.toRadians(d); float c = (float) Math.cos(a), sn = (float) Math.sin(a);
        postAff(c, -sn, px - c * px + sn * py, sn, c, py - sn * px - c * py); return true;
    }
    public boolean postRotate(float d) { return postRotate(d, 0, 0); }
    public boolean postSkew(float kx, float ky, float px, float py) { postAff(1, kx, -kx * py, ky, 1, -ky * px); return true; }
    public boolean postSkew(float kx, float ky) { return postSkew(kx, ky, 0, 0); }
    public boolean postConcat(Matrix o) { mul(m, o.m, m); return true; }

    public boolean invert(Matrix inverse) {
        float a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
        float A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
        float det = a * A + b * B + c * C;
        if (det == 0 || Float.isNaN(det)) return false;
        if (inverse != null) {
            inverse.set9(A / det, -(b * i - c * h) / det, (b * f - c * e) / det, B / det, (a * i - c * g) / det, -(a * f - c * d) / det,
                         C / det, -(a * h - b * g) / det, (a * e - b * d) / det);
        }
        return true;
    }
    public void mapPoints(float[] dst, int dstIndex, float[] src, int srcIndex, int pointCount) {
        for (int p = 0; p < pointCount; p++) {
            float x = src[srcIndex + 2 * p], y = src[srcIndex + 2 * p + 1];
            float w = m[6] * x + m[7] * y + m[8]; if (w == 0) w = 1;
            dst[dstIndex + 2 * p] = (m[0] * x + m[1] * y + m[2]) / w;
            dst[dstIndex + 2 * p + 1] = (m[3] * x + m[4] * y + m[5]) / w;
        }
    }
    public void mapPoints(float[] dst, float[] src) { mapPoints(dst, 0, src, 0, src.length / 2); }
    public void mapPoints(float[] pts) { mapPoints(pts, 0, pts, 0, pts.length / 2); }
    public void mapVectors(float[] dst, int dstIndex, float[] src, int srcIndex, int n) {
        for (int p = 0; p < n; p++) {
            float x = src[srcIndex + 2 * p], y = src[srcIndex + 2 * p + 1];
            dst[dstIndex + 2 * p] = m[0] * x + m[1] * y; dst[dstIndex + 2 * p + 1] = m[3] * x + m[4] * y;
        }
    }
    public void mapVectors(float[] v) { mapVectors(v, 0, v, 0, v.length / 2); }
    public void mapVectors(float[] dst, float[] src) { mapVectors(dst, 0, src, 0, src.length / 2); }
    private float mx(float x, float y) { float w = m[6] * x + m[7] * y + m[8]; if (w == 0) w = 1; return (m[0] * x + m[1] * y + m[2]) / w; }
    private float my(float x, float y) { float w = m[6] * x + m[7] * y + m[8]; if (w == 0) w = 1; return (m[3] * x + m[4] * y + m[5]) / w; }
    public boolean mapRect(RectF dst, RectF src) {
        float sl = src.left, st = src.top, sr = src.right, sb = src.bottom;
        float x0 = mx(sl, st), y0 = my(sl, st), x1 = mx(sr, st), y1 = my(sr, st), x2 = mx(sr, sb), y2 = my(sr, sb), x3 = mx(sl, sb), y3 = my(sl, sb);
        dst.set(Math.min(Math.min(x0, x1), Math.min(x2, x3)), Math.min(Math.min(y0, y1), Math.min(y2, y3)),
                Math.max(Math.max(x0, x1), Math.max(x2, x3)), Math.max(Math.max(y0, y1), Math.max(y2, y3)));
        return rectStaysRect();
    }
    public boolean mapRect(RectF r) { return mapRect(r, r); }
    public float mapRadius(float radius) { float[] v = { radius, 0, 0, radius }; mapVectors(v); return (float) Math.sqrt(Math.hypot(v[0], v[1]) * Math.hypot(v[2], v[3])); }
    public boolean setRectToRect(RectF src, RectF dst, ScaleToFit stf) {
        if (src.isEmpty()) { reset(); return false; }
        float sx = dst.width() / src.width(), sy = dst.height() / src.height();
        float tx, ty;
        if (stf == ScaleToFit.FILL) { tx = dst.left - src.left * sx; ty = dst.top - src.top * sy; }
        else {
            float sc = Math.min(sx, sy); sx = sy = sc;
            float dw = src.width() * sc, dh = src.height() * sc;
            float ox = 0, oy = 0;
            if (stf == ScaleToFit.CENTER) { ox = (dst.width() - dw) / 2; oy = (dst.height() - dh) / 2; }
            else if (stf == ScaleToFit.END) { ox = dst.width() - dw; oy = dst.height() - dh; }
            tx = dst.left + ox - src.left * sc; ty = dst.top + oy - src.top * sc;
        }
        set9(sx, 0, tx, 0, sy, ty, 0, 0, 1);
        return true;
    }
    public boolean setPolyToPoly(float[] src, int srcIndex, float[] dst, int dstIndex, int pointCount) {
        if (pointCount == 0) { reset(); return true; }
        if (pointCount == 1) { setTranslate(dst[dstIndex] - src[srcIndex], dst[dstIndex + 1] - src[srcIndex + 1]); return true; }
        // two or more points: a similarity from the first two (enough for the uses seen)
        float sx0 = src[srcIndex], sy0 = src[srcIndex + 1], sx1 = src[srcIndex + 2], sy1 = src[srcIndex + 3];
        float dx0 = dst[dstIndex], dy0 = dst[dstIndex + 1], dx1 = dst[dstIndex + 2], dy1 = dst[dstIndex + 3];
        float svx = sx1 - sx0, svy = sy1 - sy0, dvx = dx1 - dx0, dvy = dy1 - dy0;
        float sl = svx * svx + svy * svy; if (sl == 0) return false;
        float a = (svx * dvx + svy * dvy) / sl, b = (svx * dvy - svy * dvx) / sl;
        set9(a, -b, dx0 - (a * sx0 - b * sy0), b, a, dy0 - (b * sx0 + a * sy0), 0, 0, 1);
        return true;
    }
    @Override public boolean equals(Object o) { return o instanceof Matrix && java.util.Arrays.equals(m, ((Matrix) o).m); }
    @Override public int hashCode() { return java.util.Arrays.hashCode(m); }
    @Override public String toString() { return "Matrix" + java.util.Arrays.toString(m); }
    public String toShortString() { return java.util.Arrays.toString(m); }
    // ---- generated by tools/compat/fillmembers.py: the platform's members this class does not write (signatures only)
    public void dump(java.io.PrintWriter p0) {}
    public long ni() { return 0L; }
    // ---- end of generated members
}
