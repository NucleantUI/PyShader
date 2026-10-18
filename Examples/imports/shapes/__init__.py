"""Shapes as distance fields: a package of two modules, re-exported here.

    from shapes import *        # star, ring
    import shapes.star          # shapes.star.star(...)
"""
from .star import star
from .ring import ring

__all__ = ["star", "ring"]
