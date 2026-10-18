"""Value noise and fractal Brownian motion.

    from noise import fbm
    import noise          # noise.fbm(p), noise.value_noise(p)
"""
from .fbm import fbm, OCTAVES
from .value import value_noise

__all__ = ["fbm", "value_noise", "OCTAVES"]
