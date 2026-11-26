/// The part of the app's page script that finds an email's paragraphs and shows
/// their translations.
///
/// A paragraph is a run of inline content inside one block: what a reader takes as
/// one piece of text, wherever the email's tables and cells put it. Its inline
/// markup travels as numbered tags in the text, `<g0>…</g0>` around what is rebuilt
/// around its translation (a link, emphasis) and `<x1/>` for what is copied
/// unchanged (inline code), so the translation keeps its links. When the tags that
/// come back do not line up, the translation is shown as plain text.
///
/// The page gets three functions:
/// - `heydayReadParagraphs()` returns the paragraphs' texts, in document order;
/// - `heydayShowTranslations({index: text}, replacing)` puts translations after
///   their paragraphs, hiding the paragraphs when `replacing`;
/// - `heydayShowOriginal()` takes the translations out of view again;
/// - `heydayForgetTranslations()` empties them, before the email is translated afresh.
enum MessageTranslationScript {
    static let source = #"""
    (() => {
      const MEDIA = 'img,svg,picture,video,audio,canvas,iframe,object,embed,map,[data-heyday-image]';
      // Blocks whose content is never translated: code, controls, pictures.
      const SKIPPED = 'pre,math,code,kbd,samp,var,button,input,select,textarea,' + MEDIA;
      // Inline elements that contribute no text to a paragraph.
      const IGNORED = MEDIA + ',script,style,template,noscript,rt,rp';
      // Inline elements copied into the translation unchanged.
      const ATOMIC = 'sub,sup,math,code,kbd,samp,var';
      // Inline elements rebuilt around the matching part of the translation.
      const PAIRED = new Set(['a', 'abbr', 'b', 'cite', 'del', 'dfn', 'em', 'i', 'ins', 'mark', 'q', 's', 'small', 'strong', 'u']);
      const BLOCKS = 'address,article,aside,blockquote,center,dd,details,div,dl,dt,fieldset,figcaption,figure,footer,form,'
        + 'h1,h2,h3,h4,h5,h6,header,hgroup,li,main,nav,ol,p,pre,section,summary,table,tbody,td,tfoot,th,thead,tr,ul';
      // Beyond this many tags a translator tends to lose some, so markup is dropped.
      const MAX_SLOTS = 12;
      // Source text this short gets its translation on the same line.
      const INLINE_MAX_LENGTH = 20;
      const TAG = /<(\/?)([gx])(\d+)\s*(\/?)>/g;

      const kindOf = (element) => {
        const style = getComputedStyle(element);
        if (style.display === 'none' || style.visibility === 'hidden') return 'hidden';
        const inline = style.display.startsWith('inline') || style.display === 'contents' || style.display.startsWith('ruby');
        return inline ? 'inline' : 'block';
      };

      const hasContent = (node) => node.nodeType === Node.ELEMENT_NODE || (node.nodeValue || '').trim() !== '';

      // Every run of consecutive inline nodes inside one block.
      const collect = (root) => {
        const found = [];
        const visit = (container) => {
          let run = [];
          const close = () => {
            if (run.some(hasContent)) found.push(run);
            run = [];
          };
          for (const child of Array.from(container.childNodes)) {
            if (child.nodeType === Node.TEXT_NODE) { run.push(child); continue; }
            if (child.nodeType !== Node.ELEMENT_NODE) continue;
            const kind = kindOf(child);
            if (kind === 'hidden') continue;
            if (kind === 'inline' && child.querySelector(BLOCKS) === null) { run.push(child); continue; }
            close();
            if (!child.matches(SKIPPED)) visit(child);
          }
          close();
        };
        visit(root);
        return found;
      };

      const encode = (nodes, useTags) => {
        const slots = [];
        const one = (node) => {
          if (node.nodeType === Node.TEXT_NODE) return (node.nodeValue || '').replace(/\s+/g, ' ');
          if (node.nodeType !== Node.ELEMENT_NODE) return '';
          if (node.localName === 'br') return '\n';
          if (node.matches(IGNORED) || kindOf(node) === 'hidden') return '';
          if (node.matches(ATOMIC)) {
            const content = (node.textContent || '').replace(/\s+/g, ' ');
            if (content.trim() === '') return '';
            if (!useTags) return content;
            slots.push({ paired: false, element: node });
            return `<x${slots.length - 1}/>`;
          }
          if (!useTags || !PAIRED.has(node.localName)) return Array.from(node.childNodes, one).join('');
          const index = slots.push({ paired: true, element: node }) - 1;
          const inner = Array.from(node.childNodes, one).join('');
          return inner.trim() === '' ? inner : `<g${index}>${inner}</g${index}>`;
        };
        const text = nodes.map(one).join('').replace(/[^\S\n]+/g, ' ').replace(/ ?\n ?/g, '\n').trim();
        return { text, slots };
      };

      const stripTags = (text) => text.replace(TAG, '');

      // Worth sending: real words, and not a lone link or address, which reads the
      // same in every language.
      const isTranslatable = (plain) => {
        const text = plain.trim();
        return /\p{L}{2}/u.test(text) && !/^(?:https?:\/\/\S+|www\.\S+|\S+@\S+\.\S+|[@#]\S+)$/i.test(text);
      };

      // Text with line breaks becomes text nodes separated by <br>.
      const textNodes = (text) => text.split('\n').flatMap((line, index) => {
        const nodes = index > 0 ? [document.createElement('br')] : [];
        if (line !== '') nodes.push(document.createTextNode(line));
        return nodes;
      });

      // A copy must not repeat an id, which has to stay unique in the page.
      const copy = (element, deep) => {
        const clone = element.cloneNode(deep);
        clone.removeAttribute('id');
        for (const descendant of clone.querySelectorAll('[id]')) descendant.removeAttribute('id');
        return clone;
      };

      // The translation with its markup rebuilt, or null when its tags do not line
      // up with the paragraph's.
      const taggedNodes = (translated, slots) => {
        const roots = [];
        const open = [];
        const append = (nodes) => {
          const parent = open.length > 0 ? open[open.length - 1].element : null;
          if (parent) parent.append(...nodes); else roots.push(...nodes);
        };
        let cursor = 0;
        for (const match of translated.matchAll(TAG)) {
          append(textNodes(translated.slice(cursor, match.index)));
          cursor = match.index + match[0].length;
          const index = Number(match[3]);
          const slot = slots[index];
          if (!slot || slot.paired !== (match[2] === 'g')) return null;
          if (!slot.paired) {
            if (match[1]) return null;
            append([copy(slot.element, true)]);
          } else if (match[1]) {
            const last = open.pop();
            if (!last || last.index !== index) return null;
          } else {
            const element = copy(slot.element, false);
            append([element]);
            open.push({ index, element });
          }
        }
        append(textNodes(translated.slice(cursor)));
        return open.length === 0 ? roots : null;
      };

      // Takes a paragraph's own text out of view, or puts it back. A picture stays
      // where it is: an element holding one has its text emptied instead of being hidden.
      const setSourceHidden = (paragraph, hidden) => {
        if (paragraph.sourceHidden === hidden) return;
        paragraph.sourceHidden = hidden;
        if (!hidden) {
          for (const [node, text] of paragraph.emptied) node.nodeValue = text;
          paragraph.emptied = [];
          for (const node of paragraph.nodes) {
            if (node.nodeType === Node.ELEMENT_NODE) node.removeAttribute('data-heyday-hidden');
          }
          return;
        }
        const empty = (node) => {
          paragraph.emptied.push([node, node.nodeValue]);
          node.nodeValue = '';
        };
        for (const node of paragraph.nodes) {
          if (node.nodeType === Node.TEXT_NODE) {
            empty(node);
          } else if (node.nodeType === Node.ELEMENT_NODE && !node.matches(MEDIA)) {
            if (node.querySelector(MEDIA) === null) {
              node.setAttribute('data-heyday-hidden', '');
            } else {
              const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
              for (let text = walker.nextNode(); text; text = walker.nextNode()) {
                // A picture's own words, such as the label of one not yet loaded, are part of it.
                if (text.parentElement.closest(MEDIA) === null) empty(text);
              }
            }
          }
        }
      };

      // Found once: the email does not change under the reader, and each paragraph's
      // place for a translation is put in the page as it is found.
      let paragraphs = null;

      window.heydayReadParagraphs = () => {
        if (paragraphs === null) {
          paragraphs = [];
          for (const nodes of collect(document.body)) {
            const tagged = encode(nodes, true);
            const source = tagged.slots.length <= MAX_SLOTS ? tagged : encode(nodes, false);
            const plain = stripTags(source.text);
            if (!isTranslatable(plain)) continue;
            const target = document.createElement('font');
            target.className = 'heyday-translation ' + (plain.length <= INLINE_MAX_LENGTH ? 'heyday-inline' : 'heyday-block');
            target.dir = 'auto';
            nodes[nodes.length - 1].after(target);
            paragraphs.push({ nodes, text: source.text, slots: source.slots, target, sourceHidden: false, emptied: [], shown: false });
          }
        }
        return paragraphs.map((paragraph) => paragraph.text);
      };

      window.heydayShowTranslations = (translations, replacing) => {
        window.heydayReadParagraphs();
        for (const [key, text] of Object.entries(translations)) {
          const paragraph = paragraphs[Number(key)];
          if (!paragraph) continue;
          const plain = stripTags(text).trim();
          // Text that was already in the reader's language comes back as it went.
          paragraph.shown = plain !== '' && plain !== stripTags(paragraph.text).trim();
          paragraph.target.replaceChildren(...(paragraph.shown ? taggedNodes(text, paragraph.slots) || textNodes(stripTags(text)) : []));
          // A class of its own says the place is filled. Styling by `:empty` is not
          // enough: WebKit leaves a place filled after it was hidden undrawn.
          paragraph.target.classList.toggle('heyday-shown', paragraph.shown);
        }
        document.documentElement.dataset.heydayTranslation = replacing ? 'replacing' : 'beside';
        for (const paragraph of paragraphs) setSourceHidden(paragraph, replacing && paragraph.shown);
      };

      window.heydayShowOriginal = () => {
        delete document.documentElement.dataset.heydayTranslation;
        for (const paragraph of paragraphs || []) setSourceHidden(paragraph, false);
      };

      window.heydayForgetTranslations = () => {
        window.heydayShowOriginal();
        for (const paragraph of paragraphs || []) {
          paragraph.shown = false;
          paragraph.target.replaceChildren();
          paragraph.target.classList.remove('heyday-shown');
        }
      };
    })();
    """#
}
