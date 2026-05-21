import React, { useState, useRef, useCallback, useEffect, useId } from 'react';
import { createPortal } from 'react-dom';

interface TooltipProps {
  content: string;
  children: React.ReactElement;
  side?: 'top' | 'bottom';
  /** Skip tap-to-toggle on touch devices (use for buttons with their own click actions) */
  disableTouchToggle?: boolean;
}

const FOCUSABLE = new Set(['BUTTON', 'A', 'INPUT', 'SELECT', 'TEXTAREA']);

function mergeRefs<T>(...refs: (React.Ref<T> | undefined)[]) {
  return (value: T | null) => {
    refs.forEach((ref) => {
      if (typeof ref === 'function') ref(value);
      else if (ref) (ref as React.MutableRefObject<T | null>).current = value;
    });
  };
}

const Tooltip: React.FC<TooltipProps> = ({
  content,
  children,
  side = 'top',
  disableTouchToggle = false,
}) => {
  const [visible, setVisible] = useState(false);
  const triggerRef = useRef<HTMLElement | null>(null);
  const tooltipId = useId();
  const isTouchRef = useRef(false);
  const [coords, setCoords] = useState({ top: 0, left: 0 });

  const updatePosition = useCallback(() => {
    const el = triggerRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    setCoords({
      top: side === 'top' ? rect.top - 6 : rect.bottom + 6,
      left: rect.left + rect.width / 2,
    });
  }, [side]);

  const show = useCallback(() => {
    updatePosition();
    setVisible(true);
  }, [updatePosition]);

  const hide = useCallback(() => {
    if (!isTouchRef.current) setVisible(false);
  }, []);

  const handleTouchClick = (e: React.MouseEvent) => {
    if (disableTouchToggle || !window.matchMedia('(hover: none)').matches) return;
    e.stopPropagation();
    if (visible) {
      setVisible(false);
    } else {
      updatePosition();
      setVisible(true);
    }
  };

  useEffect(() => {
    if (!visible || !isTouchRef.current) return;
    const close = () => setVisible(false);
    document.addEventListener('click', close);
    return () => document.removeEventListener('click', close);
  }, [visible]);

  useEffect(() => {
    if (!visible) return;
    const onScroll = () => updatePosition();
    window.addEventListener('scroll', onScroll, true);
    window.addEventListener('resize', onScroll);
    return () => {
      window.removeEventListener('scroll', onScroll, true);
      window.removeEventListener('resize', onScroll);
    };
  }, [visible, updatePosition]);

  const needsTabIndex =
    !children.props.tabIndex &&
    !FOCUSABLE.has(
      typeof children.type === 'string' ? children.type.toUpperCase() : ''
    );

  const trigger = React.cloneElement(children, {
    ref: mergeRefs(
      (children as React.ReactElement & { ref?: React.Ref<HTMLElement> }).ref,
      (node: HTMLElement | null) => {
        triggerRef.current = node;
      }
    ),
    onPointerDown: (e: React.PointerEvent) => {
      children.props.onPointerDown?.(e);
      isTouchRef.current = e.pointerType === 'touch';
    },
    onMouseEnter: (e: React.MouseEvent) => {
      children.props.onMouseEnter?.(e);
      show();
    },
    onMouseLeave: (e: React.MouseEvent) => {
      children.props.onMouseLeave?.(e);
      hide();
    },
    onFocus: (e: React.FocusEvent) => {
      children.props.onFocus?.(e);
      show();
    },
    onBlur: (e: React.FocusEvent) => {
      children.props.onBlur?.(e);
      hide();
    },
    onClick: (e: React.MouseEvent) => {
      children.props.onClick?.(e);
      handleTouchClick(e);
    },
    'aria-describedby': visible
      ? tooltipId
      : children.props['aria-describedby'],
    ...(needsTabIndex ? { tabIndex: 0 } : {}),
  });

  return (
    <>
      {trigger}
      {visible &&
        createPortal(
          <div
            id={tooltipId}
            role="tooltip"
            style={{
              position: 'fixed',
              top: coords.top,
              left: coords.left,
              transform:
                side === 'top'
                  ? 'translate(-50%, -100%)'
                  : 'translate(-50%, 0)',
              zIndex: 9999,
            }}
            className="pointer-events-none px-3 py-1.5 text-xs sm:text-sm text-white bg-black/85 backdrop-blur-sm rounded-lg border border-white/20 shadow-lg max-w-[220px] text-center whitespace-normal animate-tooltip-in"
          >
            {content}
          </div>,
          document.body
        )}
    </>
  );
};

export default Tooltip;
