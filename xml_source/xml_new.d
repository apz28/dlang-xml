/*
 *
 * License: $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors: An Pham
 *
 * Copyright An Pham 2017 - xxxx.
 * Distributed under the Boost Software License, Version 1.0.
 * (See accompanying file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt)
 *
 */

module pham.xml_new;

import std.format : format;
import std.typecons : Flag, No, Yes;

import pham.xml_msg;
import pham.xml_exception;
import pham.xml_enum;
import pham.xml_util;
import pham.xml_object;
import pham.xml_buffer;
import pham.xml_string;
import pham.xml_entity_table;
import pham.xml_reader;
import pham.xml_writer;
import pham.xml_parser;

package enum defaultXmlLevels = 200;

enum XmlParseOptionFlag 
{
    none,
    preserveWhitespace = 1 << 0,
    useSax = 1 << 1,
    useSymbolTable = 1 << 2,
    validate = 1 << 3
}

struct XmlParseOptions(S)
if (isXmlString!S)
{
    alias XmlSaxAttributeEvent = bool function(XmlAttribute!S attribute);
    alias XmlSaxElementBeginEvent = void function(XmlElement!S element);
    alias XmlSaxElementEndEvent = bool function(XmlElement!S element);
    alias XmlSaxNodeEvent = bool function(XmlNode!S node);

    XmlSaxAttributeEvent onSaxAttributeNode;
    XmlSaxElementBeginEvent onSaxElementNodeBegin;
    XmlSaxElementEndEvent onSaxElementNodeEnd;
    XmlSaxNodeEvent onSaxOtherNode;

    EnumBitFlags!XmlParseOptionFlag flags = 
        EnumBitFlags!XmlParseOptionFlag(XmlParseOptionFlag.validate);

@property:
    pragma (inline, true)
    bool preserveWhitespace() const
    {
        return flags.isOn(XmlParseOptionFlag.preserveWhitespace);
    }

    pragma (inline, true)
    bool useSax() const
    {
        return flags.isOn(XmlParseOptionFlag.useSax);
    }

    pragma (inline, true)
    bool useSymbolTable() const
    {
        return flags.isOn(XmlParseOptionFlag.useSymbolTable);
    }

    pragma (inline, true)
    bool validate() const
    {
        return flags.isOn(XmlParseOptionFlag.validate);
    }
}

/** A type indicator, nodeType, of an XmlNode object

    $(XmlNodeType.element) An element. For example: <item></item> or <item/>
    $(XmlNodeType.attribute) An attribute. For example: id='123'
    $(XmlNodeType.text) The text content of a node
    $(XmlNodeType.CData) A CDATA section. For example: <![CDATA[my escaped text]]>
    $(XmlNodeType.entityReference) A reference to an entity. For example: &num;
    $(XmlNodeType.entity) An entity declaration. For example: <!ENTITY...>
    $(XmlNodeType.processingInstruction) A processing instruction. For example: <?pi test ?>
    $(XmlNodeType.comment) A comment. For example: <!-- my comment -->
    $(XmlNodeType.document) A document object that, as the root of the document tree, provides access to the entire XML document
    $(XmlNodeType.documentType) The document type declaration, indicated by the following tag. For example: <!DOCTYPE...> 
    $(XmlNodeType.documentFragment) A document fragment.
    $(XmlNodeType.notation) A notation in the document type declaration. For example, <!NOTATION...> 
    $(XmlNodeType.whitespace) White space between markup
    $(XmlNodeType.significantWhitespace) White space between markup in a mixed content model or white space within the xml:space="preserve" scope
    $(XmlNodeType.declaration) The XML declaration. For example: <?xml version='1.0'?>
    $(XmlNodeType.documentTypeAttributeList) An attribute-list declaration. For example: <!ATTLIST...>
    $(XmlNodeType.documentTypeElement) An element declaration. For example: <!ELEMENT...>
*/
enum XmlNodeType
{
    unknown = 0,
    element = 1,
    attribute = 2,
    text = 3,
    CData = 4,
    entityReference = 5,
    entity = 6,
    processingInstruction = 7,
    comment = 8, 
    document = 9,
    documentType = 10,
    documentFragment = 11,
    notation = 12,
    whitespace = 13,
    significantWhitespace = 14,
    declaration = 17,
    documentTypeAttributeList = 20,
    documentTypeElement = 21 
}

class XmlNodeFilterContext(S) : XmlObject!S
{
public:
    const(C)[] localName;
    const(C)[] name;
    const(C)[] namespaceUri;
    XmlDocument!S.EqualName equalName;

    @disable this();

    this(XmlDocument!S aDocument, const(C)[] aName)
    {
        name = aName;
        equalName = aDocument.equalName;
    }

    this(XmlDocument!S aDocument, const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        localName = aLocalName;
        namespaceUri = aNamespaceUri;
        equalName = aDocument.equalName;
    }

    final bool matchElementByName(ref XmlNodeList!S aList, XmlNode!S aNode)
    {
        if (aNode.nodeType != XmlNodeType.element)
            return false; 
        else
            return ((name == "*") || equalName(name, aNode.name));
    }

    final bool matchElementByLocalNameUri(ref XmlNodeList!S aList, XmlNode!S aNode)
    {
        if (aNode.nodeType != XmlNodeType.element)
            return false; 
        else
        {
            return ((localName == "*" || equalName(localName, aNode.localName)) &&
                    equalName(namespaceUri, aNode.namespaceUri));
        }
    }
}

/** A root xml node for all xml node objects
*/
abstract class XmlNode(S) : XmlObject!S
{
protected:
    XmlDocument!S _ownerDocument;
    XmlNode!S _attrbLast;
    XmlNode!S _childLast;
    XmlNode!S _parent;
    XmlNode!S _next;
    XmlNode!S _prev;
    XmlName!S _qualifiedName;
    debug (PhamXml)
    {
        size_t attrbVersion;
        size_t childVersion;
    }

    mixin DLink;

    final void appendChildText(XmlStringWriter!S aWriter)
    {
        for (XmlNode!S i = firstChild; i !is null; i = i.nextSibling)
        {
            if (!i.hasChildNodes)
            {
                switch (i.nodeType)
                {
                    case XmlNodeType.CData:
                    case XmlNodeType.significantWhitespace:
                    case XmlNodeType.text:
                    case XmlNodeType.whitespace:
                        aWriter.put(i.innerText);
                        break;
                    default:
                        break;
                }
            }
            else
                i.appendChildText(aWriter);
        }
    }

    final void checkAttribute(XmlNode!S aAttribute, string aOp)
    {
        if (!allowAttribute())
        {
            string msg = format(Message.eInvalidOpDelegate, shortClassName(this), aOp);
            throw new XmlInvalidOperationException(msg);
        }

        if (aAttribute !is null)
        {
            if (!isLoading())
            {
                if (aAttribute.ownerDocument !is null && aAttribute.ownerDocument !is selfOwnerDocument)
                {
                    string msg = format(Message.eNotAllowAppendDifDoc, "attribute");
                    throw new XmlInvalidOperationException(msg);
                }
            }

            if (isLoading() && selfOwnerDocument().parseOptions.validate && findAttribute(aAttribute.name) !is null)
            {
                string msg = format(Message.eAttributeDuplicated, aAttribute.name);
                throw new XmlInvalidOperationException(msg);
            }
        }
    }

    final void checkChild(XmlNode!S aChild, string aOp)
    {
        if (!allowChild())
        {
            string msg = format(Message.eInvalidOpDelegate, shortClassName(this), aOp);
            throw new XmlInvalidOperationException(msg);
        }

        if (aChild !is null)
        {
            if (!allowChildType(aChild.nodeType))
            {
                string msg = format(Message.eNotAllowChild, shortClassName(this), aOp, name, nodeType, aChild.name, aChild.nodeType);
                throw new XmlInvalidOperationException(msg);
            }

            if (!isLoading())
            {
                if (aChild.ownerDocument !is null && aChild.ownerDocument !is selfOwnerDocument)
                {
                    string msg = format(Message.eNotAllowAppendDifDoc, "child");
                    throw new XmlInvalidOperationException(msg);
                }

                if (aChild is this || isAncestorNode(aChild))
                    throw new XmlInvalidOperationException(Message.eNotAllowAppendSelf);
            }
        }
    }

    final void checkParent(XmlNode!S aNode, bool aChild, string aOp)
    {
        if (aNode._parent !is this)
        {
            string msg = format(Message.eInvalidOpFromWrongParent, shortClassName(this), aOp);
            throw new XmlInvalidOperationException(msg);
        }

        if (aChild && aNode.nodeType == XmlNodeType.attribute)
        {
            string msg = format(Message.eInvalidOpDelegate, shortClassName(this), aOp);
            throw new XmlInvalidOperationException(msg);
        }
    }

    final XmlNode!S findChild(XmlNodeType aNodeType)
    {
        for (XmlNode!S i = firstChild; i !is null; i = i.nextSibling)
        {
            if (i.nodeType == aNodeType)
                return i;
        }
        return null;
    }

    final bool findElementById(XmlNode!S aParent, const(C)[] aId, ref XmlElement!S foundElement)
    {
        const equalName = document.equalName;
        for (auto i = aParent.firstChild; i !is null; i = i.nextSibling)
        {
            if (i.nodeType == XmlNodeType.element) 
            {
                if (equalName(i.getAttributeById(), aId))
                {
                    foundElement = cast(XmlElement!S) i;
                    return true;
                }
                else if (findElementById(i, aId, foundElement))
                    return true;
            }
        }
        return false;
    }

    bool isLoading()
    {
        return selfOwnerDocument().isLoading();
    }

    /** Returns true if this node is a Text type node
        CData, comment, significantWhitespace, text & whitespace
    */
    bool isText() const
    {
        return false;
    }

    XmlDocument!S selfOwnerDocument()
    {
        return _ownerDocument;
    }

    final XmlWriter!S writeAttributes(XmlWriter!S aWriter)
    {
        assert(hasAttributes == true);

        auto attrb = firstAttribute;
        attrb.write(aWriter);

        attrb = attrb.nextSibling;
        while (attrb !is null)
        {
            aWriter.put(' ');
            attrb.write(aWriter);
            attrb = attrb.nextSibling;
        }

        return aWriter;
    }

    final XmlWriter!S writeChildren(XmlWriter!S aWriter)
    {
        assert(hasChildNodes == true);

        if (nodeType != XmlNodeType.document)
            aWriter.incNodeLevel();

        auto node = firstChild;
        while (node !is null)
        {
            node.write(aWriter);
            node = node.nextSibling;
        }        

        if (nodeType != XmlNodeType.document)
            aWriter.decNodeLevel();

        return aWriter;
    }

package:
    final XmlAttribute!S appendAttribute(XmlAttribute!S newAttribute)
    {
        checkAttribute(newAttribute, "appendAttribute()");

        if (!isLoading())
        {
            if (auto n = newAttribute.parentNode)
                n.removeAttribute(newAttribute);
        }

        newAttribute._parent = this;
        dlinkInsertEnd(_attrbLast, newAttribute);

        debug (PhamXml)
        {
            ++attrbVersion;
        }

        return newAttribute;
    }

    final bool matchElement(ref XmlNodeList!S aList, XmlNode!S aNode)
    {
        return (aNode.nodeType == XmlNodeType.element);
    }

public:
    /** Returns attribute list of this node
        If node does not have any attribute or not applicable, returns an empty list

        Returns:
            Its' attribute list
    */
    final XmlNodeList!S getAttributes()
    {
        return getAttributes(null);
    }

    /** Returns attribute list of this node
        If node does not have any attribute or not applicable, returns an empty list

        Returns:
            Its' attribute list
    */
    final XmlNodeList!S getAttributes(Object aContext)
    {
        return XmlNodeList!S(this, XmlNodeListType.attributes, null, aContext);
    }

    /** Returns child node list of this node
        If node does not have any child or not applicable, returns an empty node list

        Returns:
            Its' child node list
    */
    final XmlNodeList!S getChildNodes()
    {
        return getChildNodes(null, No.deep);
    }

    /** Returns child node list of this node
        If node does not have any child or not applicable, returns an empty node list
        If aDeep is true, it will return all sub-children

        Returns:
            Its' child node list
    */
    final XmlNodeList!S getChildNodes(Object aContext, Flag!"deep" aDeep)
    {
        if (aDeep)
            return XmlNodeList!S(this, XmlNodeListType.childNodesDeep, null, aContext);
        else
            return XmlNodeList!S(this, XmlNodeListType.childNodes, null, aContext);
    }

    /** Returns element node list of this node
        If node does not have any element node or not applicable, returns an empty node list

        Returns:
            Its' element node list
    */
    final XmlNodeList!S getElements()
    {
        return getElements(null, No.deep);
    }

    /** Returns element node list of this node
        If node does not have any element node or not applicable, returns an empty node list
        If aDeep is true, it will return all sub-elements

        Returns:
            Its' element node list
    */
    final XmlNodeList!S getElements(Object aContext, Flag!"deep" aDeep)
    {
        if (aDeep)
            return XmlNodeList!S(this, XmlNodeListType.childNodesDeep, &matchElement, aContext);
        else
            return XmlNodeList!S(this, XmlNodeListType.childNodes, &matchElement, aContext);
    }

    /** Returns element node list of this node that matches the passing parameter aName
        If node does not have any matched element node or not applicable, returns an empty list
        If aName is "*", it will return all sub-elements

        Params:
            aName = a name to be checked

        Returns:
            Its' element node list
    */
    final XmlNodeList!S getElementsByTagName(const(C)[] aName)
    {
        if (aName == "*")
            return getElements(null, Yes.deep);
        else
        {
            auto filterContext = new XmlNodeFilterContext!S(document, aName);
            return XmlNodeList!S(this, XmlNodeListType.childNodesDeep, &filterContext.matchElementByName, filterContext);
        }
    }

    /** Returns element node list of this node that matches the passing parameter aLocalName and aNamespaceUri
        If node does not have any matched element node or not applicable, returns an empty list

        Params:
            aLocalName = a localName to be checked
            aNamespaceUri = a namespaceUri to be checked

        Returns:
            Its' element node list
    */
    final XmlNodeList!S getElementsByTagName(const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        auto filterContext = new XmlNodeFilterContext!S(document, aLocalName, aNamespaceUri);
        return XmlNodeList!S(this, XmlNodeListType.childNodesDeep, &filterContext.matchElementByLocalNameUri, filterContext);
    }

    version (none)
    XmlNodeList!S opSlice()
    {
        return children(false);
    }

public:
    /** Returns true if aNode is an ancestor of this node;
        false otherwise

        Params:
            aNode = a node to be checked
    */
    final bool isAncestorNode(XmlNode!S aNode)
    {
        auto n = parentNode;
        while (n !is null && n !is this)
        {
            if (n is aNode)
                return true;
            n = n.parentNode;
        }

        return false;
    }

    /** Returns true if this node accepts attribute (can have attribute); false otherwise
    */
    bool allowAttribute() const
    {
        return false;
    }

    /** Returns true if this node accepts a node except attribute (can have child); false otherwise
    */
    bool allowChild() const
    {
        return false;
    }

    /** Returns true if this node accepts a node with aNodeType except attribute (can have child); 
        false otherwise

        Params:
            aNodeType = a node type to be checked
    */
    bool allowChildType(XmlNodeType aNodeType)
    {
        return false;
    }

    /** Inserts an attribute aName to this node at the end
        If node already has the existing attribute name matched with aName, it will return it; otherwise returns newly created attribute node
        If node does not accept attribute node, it will throw XmlInvalidOperationException exception

        Params:
            aName = a name to be checked

        Returns:
            attribute node with name, aName 
    */
    final XmlAttribute!S appendAttribute(const(C)[] aName)
    {
        checkAttribute(null, "appendAttribute()");

        XmlAttribute!S a = findAttribute(aName);
        if (a is null)
            a = appendAttribute(selfOwnerDocument.createAttribute(aName));

        return a;
    }

    /** Inserts a newChild to this node at the end and returns newChild
        If newChild is belong to a different parent node, it will be removed from that parent node before being addded
        If allowChild() or allowChildType() returns false, it will throw XmlInvalidOperationException exception

        Params:
            newChild = a child node to be appended

        Returns:
            newChild
    */
    final XmlNode!S appendChild(XmlNode!S newChild)
    {
        checkChild(newChild, "appendChild()");

        if (auto n = newChild.parentNode)
            n.removeChild(newChild);

        if (newChild.nodeType == XmlNodeType.documentFragment)
        {
            XmlNode!S next;
            XmlNode!S first = newChild.firstChild;
            XmlNode!S node = first;
            while (node !is null)
            {
                next = node.nextSibling;
                appendChild(newChild.removeChild(node));
                node = next;
            }
            return first;
        }

        newChild._parent = this;
        dlinkInsertEnd(_childLast, newChild);

        debug (PhamXml)
        {
            ++childVersion;
        }

        return newChild;
    }
    
    /** Finds an attribute matched name with aName and returns it;
        otherwise return null if no attribute with matched name found
        
        Params:
            aName = a name to be checked

        Returns:
            Found attribute node
            Otherwise null
    */
    final XmlAttribute!S findAttribute(const(C)[] aName)
    {
        const equalName = document.equalName;
        for (auto i = firstAttribute; i !is null; i = i.nextSibling)
        {
            if (equalName(i.name, aName))
                return cast(XmlAttribute!S) i;
        }
        return null;
    }

    /** Finds an attribute matched localName + namespaceUri with aLocalName + aNamespaceUri and returns it; 
        otherwise returns null if no attribute with matched localName + namespaceUri found
    
        Returns:
            Found attribute node
            Otherwise null
    */
    final XmlAttribute!S findAttribute(const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        const equalName = document.equalName;
        for (auto i = firstAttribute; i !is null; i = i.nextSibling)
        {
            if (equalName(i.localName, aLocalName) && equalName(i.namespaceUri, aNamespaceUri))
                return cast(XmlAttribute!S) i;
        }
        return null;
    }

    /** Finds an attribute matched name with caseinsensitive "ID" and returns it; 
        otherwise returns null if no attribute with such name found

        Returns:
            Found attribute node
            Otherwise null
    */
    final XmlAttribute!S findAttributeById()
    {
        for (auto i = firstAttribute; i !is null; i = i.nextSibling)
        {
            if (equalCaseInsensitive!S(i.name, "id"))
                return cast(XmlAttribute!S) i;
        }
        return null;
    }

    /** Finds an element matched name with aName and returns it;
        otherwise return null if no element with matched name found

        Params:
            aName = a name to be checked

        Returns:
            Found element node
            Otherwise null
    */
    final XmlElement!S findElement(const(C)[] aName)
    {
        const equalName = document.equalName;
        for (auto i = firstChild; i !is null; i = i.nextSibling)
        {
            if (i.nodeType == XmlNodeType.element && equalName(i.name, aName))
                return cast(XmlElement!S) i;
        }
        return null;
    }

    /** Finds an element matched localName + namespaceUri with aLocalName + aNamespaceUri and returns it; 
        otherwise returns null if no element with matched localName + namespaceUri found

        Params:
            aLocalName = a localName to be checked
            aNamespaceUri = a namespaceUri to be checked

        Returns:
            Found element node
            Otherwise null
    */
    final XmlElement!S findElement(const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        const equalName = document.equalName;
        for (auto i = firstChild; i !is null; i = i.nextSibling)
        {
            if (i.nodeType == XmlNodeType.element && 
                equalName(i.localName, aLocalName) && 
                equalName(i.namespaceUri, aNamespaceUri))
                return cast(XmlElement!S) i;
        }
        return null;
    }

    /** Finds an attribute matched name with aName and returns its' value;
        otherwise return null if no attribute with matched name found

        Params:
            aName = a named to be checked

        Returns:
            Its' found attribute value
            Otherwise null
    */
    final const(C)[] getAttribute(const(C)[] aName)
    {
        auto a = findAttribute(aName);
        if (a is null)
            return null;
        else
            return a.value;
    }

    /** Finds an attribute matched localName + namespaceUri with aLocalName + aNamespaceUri and returns its' value; 
        otherwise returns null if no attribute with matched localName + namespaceUri found

        Params:
            aLocalName = a localName to be checked
            aNamespaceUri = a namespaceUri to be checked

        Returns:
            Its' found attribute value
            Otherwise null
    */
    final const(C)[] getAttribute(const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        auto a = findAttribute(aLocalName, aNamespaceUri);
        if (a is null)
            return null;
        else
            return a.value;
    }

    /** Finds an attribute matched name with caseinsensitive "ID" and returns its' value; 
        otherwise returns null if no attribute with such name found
    */
    final const(C)[] getAttributeById()
    {
        auto a = findAttributeById();
        if (a is null)
            return null;
        else
            return a.value;
    }

    /** Finds an element that have the mached attribute name aId and returns it;
        otherwise return null if no element with such id named found

        Params:
            aId = an search attribute value of named "id"

        Returns:
            Found element node
            Otherwise null            
    */
    final XmlElement!S getElementById(const(C)[] aId)
    {
        XmlElement!S result;
        if (findElementById(this, aId, result))
            return result;
        else
            return null;
    }

    /** Implement opIndex operator based on matched aName
    */
    final XmlElement!S opIndex(const(C)[] aName)
    {
        return findElement(aName);
    }

    /** Implement opIndex operator based on matched aLocalName + aNamespaceUri
    */
    final XmlElement!S opIndex(const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        return findElement(aLocalName, aNamespaceUri);
    }

    /** Insert a child node, newChild, after anchor node, refChild and returns refChild
        If newChild is belong to a different parent node, it will be removed from that parent node before being inserted
        If allowChild() or allowChildType() returns false, it will throw XmlInvalidOperationException exception

        Params:
            newChild = a child node to be inserted
            refChild = a anchor node to as reference to position, newChild, after

        Returns:
            newChild
    */
    final XmlNode!S insertChildAfter(XmlNode!S newChild, XmlNode!S refChild)
    {
        checkChild(newChild, "insertChildAfter()");

        if (refChild is null)
            return appendChild(newChild);

        checkParent(refChild, true, "insertChildAfter()");

        if (auto n = newChild.parentNode)
            n.removeChild(newChild);

        if (newChild.nodeType == XmlNodeType.documentFragment)
        {
            XmlNode!S next;
            XmlNode!S first = newChild.firstChild;
            XmlNode!S node = first;
            while (node !is null)
            {
                next = node.nextSibling;
                insertChildAfter(newChild.removeChild(node), refChild);
                refChild = node;
                node = next;
            }
            return first;
        }

        newChild._parent = this;
        dlinkInsertAfter(refChild, newChild);

        debug (PhamXml)
        {
            ++childVersion;
        }

        return newChild;
    }

    /** Insert a child node, newChild, before anchor node, refChild and returns refChild
        If newChild is belong to a different parent node, it will be removed from that parent node before being inserted
        If allowChild() or allowChildType() returns false, it will throw XmlInvalidOperationException exception

        Params:
            newChild = a child node to be inserted
            refChild = a anchor node to as reference to position, newChild, before

        Returns:
            newChild
    */
    final XmlNode!S insertChildBefore(XmlNode!S newChild, XmlNode!S refChild)
    {
        checkChild(newChild, "insertChildBefore()");

        if (refChild is null)
            return appendChild(newChild);

        checkParent(refChild, true, "insertChildBefore()");

        if (auto n = newChild.parentNode)
            n.removeChild(newChild);

        if (newChild.nodeType == XmlNodeType.documentFragment)
        {
            XmlNode!S first = newChild.firstChild;
            XmlNode!S node = first;
            if (node !is null)
            {
                insertChildBefore(newChild.removeChild(node), refChild);
                // insert the rest of the children after this one.
                insertChildAfter(newChild, node);
            }
            return first;
        }

        newChild._parent = this;
        dlinkInsertAfter(refChild._prev, newChild);

        debug (PhamXml)
        {
            ++childVersion;
        }

        return newChild;
    }

    /** Returns string of xml structure of this node

        Params:
            aPrettyOutput = a boolean value to indicate if output xml should be nicely formated

        Returns:
            string of xml structure
    */
    final const(C)[] outerXml(Flag!"PrettyOutput" aPrettyOutput = No.PrettyOutput)
    {
        auto buffer = selfOwnerDocument.acquireBuffer(nodeType);
        write(new XmlStringWriter!S(aPrettyOutput, buffer));
        return selfOwnerDocument.getAndReleaseBuffer(buffer);
    }

    /** Remove all its' child, sub-child and attribute nodes
    */
    final void removeAll()
    {
        removeChildNodes(Yes.deep);
        removeAttributes();
    }

    /** Remove an attribute, removedAttribute, from its attribute list
        If removedAttribute is not belonged to this node, it will throw XmlInvalidOperationException

        Params:
            removedAttribute = an attribute to be removed

        Returns:
            removedAttribute
    */
    final XmlAttribute!S removeAttribute(XmlAttribute!S removedAttribute)
    {
        checkParent(removedAttribute, false, "removeAttribute()");

        removedAttribute._parent = null;
        dlinkRemove(_attrbLast, removedAttribute);

        debug (PhamXml)
        {
            ++attrbVersion;
        }

        return removedAttribute;
    }

    /** Remove an attribute with name, aName, from its' attribute list

        Params:
            aName = an attribute name to be removed

        Returns:
            An attribute with name, aName, if found
            Otherwise null
    */
    final XmlAttribute!S removeAttribute(const(C)[] aName)
    {
        XmlAttribute!S r = findAttribute(aName);
        if (r is null)
            return null;
        else
            return removeAttribute(r);
    }

    /** Remove all its' attribute nodes
    */
    void removeAttributes()
    {
        if (_attrbLast !is null)
        {
            while (_attrbLast !is null)
            {
                _attrbLast._parent = null;
                dlinkRemove(_attrbLast, _attrbLast);
            }

            debug (PhamXml)
            {
                ++attrbVersion;
            }
        }
    }

    /** Remove all its' child nodes or all its sub-nodes if aDeep is true

        Params:
            aDeep = true indicates if a removed node to recursively call removeChildNodes
    */
    void removeChildNodes(Flag!"deep" aDeep = No.deep)
    {
        if (_childLast !is null)
        {
            while (_childLast !is null)
            {
                if (aDeep)
                    _childLast.removeChildNodes(Yes.deep);
                _childLast._parent = null;
                dlinkRemove(_childLast, _childLast);
            }

            debug (PhamXml)
            {
                ++childVersion;
            }
        }
    }

    /** Remove an child node, removedChild, from its' child node list
        If removedChild is not belonged to this node, it will throw XmlInvalidOperationException

        Params:
            removedChild = a child node to be removed

        Returns:
            removedChild
    */
    final XmlNode!S removeChild(XmlNode!S removedChild)
    {
        checkParent(removedChild, true, "removeChild()");

        removedChild._parent = null;
        dlinkRemove(_childLast, removedChild);

        debug (PhamXml)
        {
            ++childVersion;
        }

        return removedChild;
    }

    /** Replace an child node, oldChild, with newChild
        If newChild is belong to a different parent node, it will be removed from that parent node
        If oldChild is not belonged to this node, it will throw XmlInvalidOperationException
        If allowChild() or allowChildType() returns false, it will throw XmlInvalidOperationException exception

        Params:
            newChild = a child node to be placed into
            oldChild = a child node to be replaced

        Returns:
            oldChild
    */
    final XmlNode!S replaceChild(XmlNode!S newChild, XmlNode!S oldChild)
    {
        checkChild(newChild, "replaceChild()");
        checkParent(oldChild, true, "replaceChild()");

        XmlNode!S pre = oldChild.previousSibling;

        oldChild._parent = null;
        dlinkRemove(_childLast, oldChild);

        insertChildAfter(newChild, pre);

        return oldChild;
    }

    /** Find an attribute with name matched aName and set its value to aValue
        If no attribute found, it will create a new attribute and set its' value
        If node does not accept attribute node, it will throw XmlInvalidOperationException exception

        Params:
            aName = an attribute name to be added
            aValue = the value of the attribute node

        Returns:
            attribute node
    */
    final XmlAttribute!S setAttribute(const(C)[] aName, const(C)[] aValue)
    {
        checkAttribute(null, "setAttribute()");

        XmlAttribute!S a = findAttribute(aName);
        if (a is null)
            a = appendAttribute(selfOwnerDocument.createAttribute(aName));
        a.value = aValue;
        return a;
    }

    /** Find an attribute with localnamne + namespaceUri matched aLocalName + aNamespaceUri and set its value to aValue
        If no attribute found, it will create a new attribute and set its' value
        If node does not accept attribute node, it will throw XmlInvalidOperationException exception

        Params:
            aLocalName = an attribute localname to be added
            aNamespaceUri = an attribute namespaceUri to be added
            aValue = the value of the attribute node

        Returns:
            attribute node
    */
    final XmlAttribute!S setAttribute(const(C)[] aLocalName, const(C)[] aNamespaceUri, const(C)[] aValue)
    {
        checkAttribute(null, "setAttribute()");

        XmlAttribute!S a = findAttribute(aLocalName, aNamespaceUri);
        if (a is null)
            a = appendAttribute(selfOwnerDocument.createAttribute("", aLocalName, aNamespaceUri));
        a.value = aValue;
        return a;
    }

    /** Write out xml to aWriter according to its' structure

        Params:
            aWriter = output range to accept this node string xml structure

        Returns:
            aWriter
    */
    abstract XmlWriter!S write(XmlWriter!S aWriter);

@property:
    /** Returns its' attribute node list
    */
    XmlNodeList!S attributes()
    {
        return getAttributes(null);
    }

    /** Returns its' child node list
    */
    XmlNodeList!S childNodes()
    {
        return getChildNodes(null, No.deep);
    }

    /** Returns its' document node
    */
    XmlDocument!S document()
    {
        XmlDocument!S d;

        if (_parent !is null)
        {
            if (_parent.nodeType == XmlNodeType.document)
                return cast(XmlDocument!S) _parent;
            else
                d = _parent.document;
        }

        if (d is null)
        {
            d = ownerDocument;
            if (d is null)
                return selfOwnerDocument;
        }

        return d;
    }

    /** Returns its' first attribute node
        A null if node has no attribute
    */
    final XmlNode!S firstAttribute()
    {
        if (_attrbLast is null)
            return null;
        else
            return _attrbLast._next;
    }

    /** Returns its' first child node
        A null if node has no child
    */
    final XmlNode!S firstChild()
    {
        if (_childLast is null)
            return null;
        else
            return _childLast._next;
    }

    /** Return true if a node has any attribute node
        false otherwise
    */
    final bool hasAttributes()
    {
        return (_attrbLast !is null);
    }

    /** Return true if a node has any child node
        false otherwise
    */
    final bool hasChildNodes()
    {
        return (_childLast !is null);
    }

    /** Returns true if a node has any value
        false otherwise

        Params:
            checkContent = further check if value is empty or not
    */
    final bool hasValue(Flag!"checkContent" checkContent)
    {
        switch (nodeType)
        {
            case XmlNodeType.attribute:
            case XmlNodeType.CData:
            case XmlNodeType.comment:
            case XmlNodeType.processingInstruction:
            case XmlNodeType.text:
            case XmlNodeType.significantWhitespace:
            case XmlNodeType.whitespace:
            case XmlNodeType.declaration:
                return (!checkContent || value.length > 0);
            default:
                return false;
        }
    }

    /** Returns string of all its' child node text/value
    */
    const(C)[] innerText()
    {
        auto first = firstChild;
        if (first is null)
            return null;
        else if (isOnlyNode(first) && first.isText)
            return first.innerText;
        else
        {
            auto buffer = selfOwnerDocument.acquireBuffer(nodeType);
            appendChildText(new XmlStringWriter!S(No.PrettyOutput, buffer));
            return selfOwnerDocument.getAndReleaseBuffer(buffer);
        }
    }

    const(C)[] innerText(const(C)[] newValue)
    {
        auto first = firstChild;
        if (isOnlyNode(first) && first.nodeType == XmlNodeType.text)
            first.innerText = newValue;
        else
        {
            removeChildNodes(Yes.deep);
            appendChild(selfOwnerDocument.createText(newValue));
        }
        return newValue;
    }

    final bool isNamespaceNode()
    {
        return (nodeType == XmlNodeType.attribute &&                
                localName.length > 0 &&                
                value.length > 0 &&
                document.equalName(prefix, toUTF!(string, S)(XmlConst.xmlns)));
    }

    /** Returns true if aNode is the only child/attribute node (no sibling node)
        false otherwise
    */
    final bool isOnlyNode(XmlNode!S aNode) const
    {
        return (aNode !is null && 
                aNode.previousSibling is null &&
                aNode.nextSibling is null);
    }

    /** Returns its' last attribute node
        A null if node has no attribute
    */
    final XmlNode!S lastAttribute()
    {
        return _attrbLast;
    }

    /** Returns its' last child node
        A null if node has no child
    */
    final XmlNode!S lastChild()
    {
        return _childLast;
    }

    /** Returns level within its' node hierarchy
    */
    size_t level()
    {
        if (parentNode is null)
            return 0;
        else
            return (parentNode.level + 1);
    }

    final const(C)[] localName()
    {
        return _qualifiedName.localName;
    }

    final const(C)[] name()
    {
        return _qualifiedName.name;
    }

    final const(C)[] namespaceUri()
    {
        return _qualifiedName.namespaceUri;
    }

    /** Returns its' next sibling node
        A null if node has no sibling
    */
    final XmlNode!S nextSibling()
    {
        if (parentNode is null)
            return _next;

        XmlNode!S last;
        if (nodeType == XmlNodeType.attribute)
            last = parentNode.lastAttribute;
        else
            last = parentNode.lastChild;

        if (this is last)
            return null;
        else
            return _next;
    }

    /** Returns an enum of XmlNodeType of its' presentation
    */
    abstract XmlNodeType nodeType() const;

    final XmlDocument!S ownerDocument()
    {
        return _ownerDocument;
    }

    /** Returns its' parent node if any
        null otherwise
    */
    final XmlNode!S parentNode()
    {
        return _parent;
    }

    version (none)
    final ptrdiff_t indexOf()
    {
        if (auto p = parentNode())
        {
            ptrdiff_t result = 0;
            if (nodeType == XmlNodeType.attribute)
            {
                auto e = p.firstAttribute;
                while (e !is null)
                {
                    if (e is this)
                        return result;
                    ++result;
                    e = e.nextSibling;
                }
            }
            else
            {
                auto e = p.firstChild;
                while (e !is null)
                {
                    if (e is this)
                        return result;
                    ++result;
                    e = e.nextSibling;
                }
            }
        }

        return -1;
    }

    /** Returns prefix string of its' qualified name if any
    */
    final const(C)[] prefix()
    {
        return _qualifiedName.prefix;
    }

    const(C)[] prefix(const(C)[] newValue)
    {
        string msg = format(Message.eInvalidOpDelegate, shortClassName(this), "prefix()");
        throw new XmlInvalidOperationException(msg);
    }

    /** Returns its' previous sibling node
        A null if node has no sibling
    */
    final XmlNode!S previousSibling()
    {
        if (parentNode is null)
            return _prev;

        XmlNode!S first;
        if (nodeType == XmlNodeType.attribute)
            first = parentNode.firstAttribute;
        else
            first = parentNode.firstChild;

        if (this is first)
            return null;
        else
            return _prev;
    }

    const(C)[] value()
    {
        return null;
    }

    const(C)[] value(const(C)[] newValue)
    {
        string msg = format(Message.eInvalidOpDelegate, shortClassName(this), "value()");
        throw new XmlInvalidOperationException(msg);
    }
}

/** A state of a XmlNodeList struct

    $(XmlNodeListType.attributes) A node list represents of attribute nodes
    $(XmlNodeListType.childNodes) A node list represents of xml nodes except attribute node
    $(XmlNodeListType.childNodesDeep) Similar to childNodes but it includes all sub-nodes
    $(XmlNodeListType.flat) A array type of node list
*/
enum XmlNodeListType
{
    attributes,
    childNodes,
    childNodesDeep,
    flat
}

/** A struct type for holding various xml node objects
    It implements range base api
*/
struct XmlNodeList(S)
if (isXmlString!S)
{
public:
    alias XmlNodeListFilterEvent = bool delegate(ref XmlNodeList!S aList, XmlNode!S aNode);

private:
    struct WalkNode
    {
        XmlNode!S parent, next;
        debug (PhamXml) size_t parentVersion;

        this(XmlNode!S aParent, XmlNode!S aNext)
        {
            parent = aParent;
            next = aNext;
            debug (PhamXml)
                parentVersion = aParent.childVersion;
        }
    }

    Object _context;
    XmlNode!S _orgParent, _parent, _current;
    XmlNode!S[] _flatList;
    WalkNode[] _walkNodes;
    XmlNodeListFilterEvent _onFilter;
    size_t _currentIndex;
    size_t _length = size_t.max;
    int _inFilter;
    XmlNodeListType _listType;
    bool _emptyList;

    debug (PhamXml)
    {
        size_t _parentVersion;

        pragma (inline, true)
        size_t getVersionAttrb()
        {
            return _parent.attrbVersion;
        }

        pragma (inline, true)
        size_t getVersionChild()
        {
            return _parent.childVersion;
        }

        void checkVersionChangedAttrb()
        {
            if (_parentVersion != getVersionAttrb())
                throw new XmlException(Message.EAttributeListChanged);
        }

        void checkVersionChangedChild()
        {
            if (_parentVersion != getVersionChild())
                throw new XmlException(Message.EChildListChanged);
        }

        pragma (inline, true)
        void checkVersionChanged()
        {
            if (_listType == XmlNodeListType.Attributes)
                checkVersionChangedAttrb();
            else
                checkVersionChangedChild();
        }
    }

    void checkFilter(void delegate() aAdvance)
    in
    {
        assert(_listType != XmlNodeListType.flat);
    }
    body
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.checkFilter()");

        ++_inFilter;
        scope (exit)
            --_inFilter;

        while (_current !is null && !_onFilter(this, _current))
            aAdvance();
    }

    void popFrontSibling()
    in
    {
        assert(_listType != XmlNodeListType.flat);
        assert(_current !is null);
    }
    body
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.popFrontSibling()");

        _current = _current.nextSibling;

        if (_inFilter == 0 && _onFilter !is null)
            checkFilter(&popFrontSibling);
    }

    void popFrontDeep()
    in
    {
        assert(_listType != XmlNodeListType.flat);
        assert(_current !is null);
    }
    body
    {
        version (none)
        version (unittest)
        outputXmlTraceParserF("XmlNodeList.popFrontDeep(current(%s.%s))", _parent.name, _current.name);

        if (_current.hasChildNodes)
        {
            if (_current.nextSibling !is null)
            {
                version (none)
                version (unittest)
                outputXmlTraceParserF("XmlNodeList.popFrontDeep(push(%s.%s))", _parent.name,
                    _current.nextSibling.name);

                _walkNodes ~= WalkNode(_parent, _current.nextSibling);
            }

            _parent = _current;
            _current = _current.firstChild;
            debug (PhamXml)
                _parentVersion = getVersionChild();
        }
        else
        {
            _current = _current.nextSibling;
            while (_current is null && _walkNodes.length > 0)
            {
                size_t index = _walkNodes.length - 1;
                _parent = _walkNodes[index].parent;
                _current = _walkNodes[index].next;
                debug (PhamXml)
                    _parentVersion = _walkNodes[index].parentVersion;

                _walkNodes.length = index;
            }
        }

        if (_inFilter == 0 && _onFilter !is null)
            checkFilter(&popFrontDeep);
    }

    XmlNode!S getItemSibling(size_t aIndex)
    in
    {
        assert(_listType != XmlNodeListType.flat);
    }
    body
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.getItem()");

        if (_current is null || aIndex == 0)
            return _current;

        auto restore = this;

        while (aIndex > 0 && _current !is null)
        {
            popFrontSibling();
            --aIndex;
        }

        auto result = _current;
        this = restore;

        if (aIndex == 0)
            return result;
        else
            return null;
    }

    XmlNode!S getItemDeep(size_t aIndex)
    in
    {
        assert(_listType != XmlNodeListType.flat);
    }
    body
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.getItemDeep()");

        if (_current is null || aIndex == 0)
            return _current;

        auto restore = this;

        while (aIndex > 0 && _current !is null)
        {
            popFrontDeep();
            --aIndex;
        }

        auto result = _current;
        this = restore;

        if (aIndex == 0)
            return result;
        else
            return null;
    }

    version (none)
    void moveBackSibling()
    in
    {
        assert(_listType != XmlNodeListType.flat);
        assert(_current !is null);
    }
    body
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.moveBackSibling()");

        _current = _current.previousSibling;

        if (_inFilter == 0 && _onFilter !is null)
            checkFilter(&moveBackSibling);
    }

public:
    this(this)
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.this(this)");

        if (_listType == XmlNodeListType.childNodesDeep)
            _walkNodes = _walkNodes.dup;
    }

    this(XmlNode!S aParent, XmlNodeListType aListType, XmlNodeListFilterEvent aOnFilter, Object aContext)
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.this(...)");

        if (aListType == XmlNodeListType.flat)
        {
            string msg = format(Message.eInvalidOpDelegate, "XmlNodeList", "this(listType = XmlNodeListType.flat)");
            throw new XmlInvalidOperationException(msg);
        }

        _orgParent = aParent;
        _listType = aListType;
        _onFilter = aOnFilter;
        _context = aContext;

        if (_listType == XmlNodeListType.childNodesDeep)
            _walkNodes.reserve(defaultXmlLevels);

        reset();
    }

    this(Object aContext)
    {
        _context = aContext;
        _listType = XmlNodeListType.flat;
    }

    /** Returns the last item in the list

        Returns:
            xml node object
    */
    XmlNode!S back()
    {
        if (_listType == XmlNodeListType.flat)
            return _flatList[$ - 1];
        else
            return item(length() - 1);
    }

    /** Insert xml node, aNode, to the end
        Valid only if list-type is XmlNodeListType.flat

        Params:
            aNode = a xml node to be inserted

        Returns:
            aNode
    */
    XmlNode!S insertBack(XmlNode!S aNode)
    {
        if (_listType != XmlNodeListType.flat)
        {
            string msg = format(Message.eInvalidOpDelegate, "XmlNodeList", "insertBack(listType != XmlNodeListType.flat)");
            throw new XmlInvalidOperationException(msg);
        }

        _flatList ~= aNode;
        return aNode;
    }

    /** Returns the item in the list at index, aIndex

        Params:
            aIndex = where a xml node to be returned

        Returns:
            xml node object
    */
    XmlNode!S item(size_t aIndex)
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.item()");

        if (_listType == XmlNodeListType.flat)
        {
            size_t i = aIndex + _currentIndex;
            if (i < _flatList.length)
                return _flatList[i];
            else
                return null;
        }
        else
        {
            debug (PhamXml)
                checkVersionChanged();

            if (empty)
                return null;

            if (_listType == XmlNodeListType.childNodesDeep)
                return getItemDeep(aIndex);
            else
                return getItemSibling(aIndex);
        }
    }

    /** Returns the count of xml nodes
        It can be expensive operation

        Returns:
            count of xml nodes
    */
    size_t length()
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.length()");

        if (empty)
            return 0;

        if (_listType == XmlNodeListType.flat)
            return _flatList.length - _currentIndex;
        else
        {
            debug (PhamXml)
                checkVersionChanged();

            if (_length == size_t.max)
            {
                size_t tempLength;
                auto restore = this;

                while (_current !is null)
                {
                    ++tempLength;
                    popFront();
                }

                this = restore;
                _length = tempLength;
            }

            return _length;
        }
    }

    /** A range based operation by moving current position to the next item
        and returns the current node object

        Returns:
            Current xml node object before the call
    */
    XmlNode!S moveFront()
    {
        XmlNode!S f = front;
        popFront();
        return f;
    }

    /** A range based operation by moving current position to the next item
    */
    void popFront()
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.popFront()");

        if (_listType == XmlNodeListType.flat)
            ++_currentIndex;
        else
        {
            debug (PhamXml)
                checkVersionChanged();

            if (_listType == XmlNodeListType.childNodesDeep)
                popFrontDeep();
            else
                popFrontSibling();
            _length = size_t.max;
        }
    }

    /** Returns the index of aNode in this node-list
        if aNode is not in the list, returns -1
        Based 1 value

        Params:
            aNode = a xml node to be calculated

        Returns:
            A index in the list if found
            otherwise -1
    */
    ptrdiff_t indexOf(XmlNode!S aNode)
    {
        for (ptrdiff_t i = 0; i < length; ++i)
        {
            if (aNode is item(i))
                return i;
        }

        return -1;
    }

    void removeAll()
    {
        final switch (_listType)
        {
            case XmlNodeListType.attributes:
                _orgParent.removeAttributes();
                break;
            case XmlNodeListType.childNodes:
                _orgParent.removeChildNodes(No.deep);
                break;
            case XmlNodeListType.childNodesDeep:
                _orgParent.removeChildNodes(Yes.deep);
                break;
            case XmlNodeListType.flat:
                _flatList.length = 0;
                break;
        }

        reset();
    }

    void reset()
    {
        version (none)
        version (unittest)
        outputXmlTraceParser("XmlNodeList.reset()");

        if (_listType == XmlNodeListType.flat)
            _currentIndex = 0;
        else
        {
            _parent = _orgParent;
            switch (_listType)
            {
                case XmlNodeListType.attributes:
                    _current = _parent.firstAttribute;
                    break;
                case XmlNodeListType.childNodes:
                case XmlNodeListType.childNodesDeep:
                    _current = _parent.firstChild;
                    break;
                default:
                    assert(0);
            }

            debug (PhamXml)
            {
                if (_listType == XmlNodeListType.Attributes)
                    _parentVersion = getVersionAttrb();
                else
                    _parentVersion = getVersionChild();
            }

            if (_onFilter !is null)
                checkFilter(&popFront);

            _emptyList = _current is null;
            if (empty)
                _length = 0;
            else
                _length = size_t.max;
        }
    }

@property:
    Object context()
    {
        return _context;
    }

    bool empty()
    {
        if (_listType == XmlNodeListType.flat)
            return (_currentIndex >= _flatList.length);
        else
            return (_current is null || _emptyList);
    }

    XmlNode!S front()
    {
        if (_listType == XmlNodeListType.flat)
            return _flatList[_currentIndex];
        else
            return _current;
    }

    XmlNode!S parent()
    {
        return _orgParent;
    }

    auto save()
    {
        return this;
    }
}

/** A xml attribute node object
*/
class XmlAttribute(S) : XmlNode!S
{
protected:
    XmlString!S _text;

package:
    this(XmlDocument!S aOwnerDocument, XmlName!S aName, XmlString!S aText)
    {
        if (!aOwnerDocument.isLoading())
        {
            checkName!(S, Yes.allowEmpty)(aName.prefix);
            checkName!(S, No.allowEmpty)(aName.localName);
        }

        _ownerDocument = aOwnerDocument;
        _qualifiedName = aName;
        _text = aText;
    }

public:
    this(XmlDocument!S aOwnerDocument, XmlName!S aName)
    {
        if (!aOwnerDocument.isLoading())
        {
            checkName!(S, Yes.allowEmpty)(aName.prefix);
            checkName!(S, No.allowEmpty)(aName.localName);
        }

        _ownerDocument = aOwnerDocument;
        _qualifiedName = aName;
    }

    this(XmlDocument!S aOwnerDocument, XmlName!S aName, const(C)[] aText)
    {
        this(aOwnerDocument, aName);
        _text = XmlString!S(aText);
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.putAttribute(name, ownerDocument.getEncodedText(_text));
        return aWriter;
    }

@property:
    final override const(C)[] innerText()
    {
        return value;
    }

    final override const(C)[] innerText(const(C)[] newValue)
    {
        return value(newValue);
    }

    final override size_t level()
    {
        if (parentNode is null)
            return 0;
        else
            return parentNode.level;
    }

    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.attribute;
    }

    final override const(C)[] prefix(const(C)[] newValue)
    {
        _qualifiedName = ownerDocument.createName(newValue, localName, namespaceUri);
        return newValue;
    }

    final override const(C)[] value()
    {
        return ownerDocument.getDecodedText(_text);
    }

    final override const(C)[] value(const(C)[] newValue)
    {
        _text = newValue;
        return newValue;
    }
}

/** A xml CData node object
*/
class XmlCData(S) : XmlCharacterDataCustom!S
{
protected:
    __gshared static XmlName!S _defaultQualifiedName;

    static XmlName!S createDefaultQualifiedName()
    {
        return new XmlName!S(toUTF!(string, S)(XmlConst.CDataTagName));
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aData)
    {
        super(aOwnerDocument, XmlString!S(aData, XmlEncodeMode.none));
        _qualifiedName = singleton!(XmlName!S)(_defaultQualifiedName, &createDefaultQualifiedName);
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.putCData(_text.value);
        return aWriter;
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.CData;
    }
}

/** A xml comment node object
*/
class XmlComment(S) : XmlCharacterDataCustom!S
{
protected:
    __gshared static XmlName!S _defaultQualifiedName;

    static XmlName!S createDefaultQualifiedName()
    {
        return new XmlName!S(toUTF!(string, S)(XmlConst.commentTagName));
    }

package:
    this(XmlDocument!S aOwnerDocument, XmlString!S aText)
    {
        super(aOwnerDocument, aText);
        _qualifiedName = singleton!(XmlName!S)(_defaultQualifiedName, &createDefaultQualifiedName);
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aText)
    {
        super(aOwnerDocument, aText);
        _qualifiedName = singleton!(XmlName!S)(_defaultQualifiedName, &createDefaultQualifiedName);
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.putComment(ownerDocument.getEncodedText(_text));
        return aWriter;
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.comment;
    }
}

/** A xml declaration node object
*/
class XmlDeclaration(S) : XmlNode!S
{
protected:
    __gshared static XmlName!S _defaultQualifiedName;

    static XmlName!S createDefaultQualifiedName()
    {
        return new XmlName!S(toUTF!(string, S)(XmlConst.declarationTagName));
    }

protected:
    const(C)[] _innerText;

    final void breakText(const(C)[] s)
    {
        import std.array : split;

        const(C)[][] t = s.split();
        foreach (e; t)
        {
            const(C)[] name, value;
            splitNameValueD!S(e, '=', name, value);

            const equalName = document.equalName;
            if (equalCaseInsensitive!S(name, toUTF!(string, S)(XmlConst.declarationVersionName)))
                versionStr = value;
            else if (equalCaseInsensitive!S(name, toUTF!(string, S)(XmlConst.declarationEncodingName)))
                encoding = value;
            else if (equalCaseInsensitive!S(name, toUTF!(string, S)(XmlConst.declarationStandaloneName)))
                standalone = value;
            else
            {
                string msg = format(Message.eInvalidName, name);
                throw new XmlException(msg);
            }
        }
    }

    final const(C)[] buildText()
    {
        if (_innerText.length == 0)
        {
            auto buffer = selfOwnerDocument.acquireBuffer(nodeType);
            auto writer = new XmlStringWriter!S(No.PrettyOutput, buffer);

            const(C)[] s;

            writer.putAttribute(toUTF!(string, S)(XmlConst.declarationVersionName), versionStr);

            s = encoding;
            if (s.length > 0)
            {
                writer.put(' ');
                writer.putAttribute(toUTF!(string, S)(XmlConst.declarationEncodingName), s);
            }

            s = standalone;
            if (s.length > 0)
            {
                writer.put(' ');
                writer.putAttribute(toUTF!(string, S)(XmlConst.declarationStandaloneName), s);
            }

            _innerText = buffer.valueAndClear();
            selfOwnerDocument.releaseBuffer(buffer);
        }

        return _innerText;
    }

    final void checkStandalone(const(C)[] s)
    {
        if ((s.length > 0) && 
            (s != toUTF!(string, S)(XmlConst.yes) || 
             s != toUTF!(string, S)(XmlConst.no)))
        {
            string msg = format(Message.eInvalidTypeValueOf2, XmlConst.declarationStandaloneName, XmlConst.yes, XmlConst.no, s);
            throw new XmlException(msg);
        }
    }

    final void checkVersion(const(C)[] s) // rule 26
    {
        if (!isVersionStr!(S, Yes.allowEmpty)(s))
        {
            string msg = format(Message.eInvalidVersionStr, s);
            throw new XmlException(msg);
        }
    }

public:
    this(XmlDocument!S aOwnerDocument)
    {
        _ownerDocument = aOwnerDocument;
        _qualifiedName = singleton!(XmlName!S)(_defaultQualifiedName, &createDefaultQualifiedName);
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aVersionStr, const(C)[] aEncoding, const(C)[] aStandalone)
    {
        checkStandalone(aStandalone);
        checkVersion(aVersionStr);

        this(aOwnerDocument);
        versionStr = aVersionStr;
        encoding = aEncoding;
        standalone = aStandalone;
    }

    final override bool allowAttribute() const
    {
        return true;
    }

    final void setDefaults()
    {
        if (versionStr.length == 0)
            versionStr = "1.0";
        if (encoding.length == 0)
            encoding = "utf-8";
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        Flag!"hasAttribute" a;
        if (hasAttributes)
            a = Yes.hasAttribute;

        aWriter.putElementNameBegin("?xml", a);
        if (a)
            writeAttributes(aWriter);
        aWriter.putElementNameEnd("?xml", No.hasChild);
        return aWriter;
    }

@property:
    final const(C)[] encoding()
    {
        return getAttribute(toUTF!(string, S)(XmlConst.declarationEncodingName));
    }

    final void encoding(const(C)[] newValue)
    {
        _innerText = null;
        if (newValue.length == 0)
            removeAttribute(toUTF!(string, S)(XmlConst.declarationEncodingName));
        else
            setAttribute(toUTF!(string, S)(XmlConst.declarationEncodingName), newValue);
    }

    final override const(C)[] innerText()
    {
        return buildText();
    }

    final override const(C)[] innerText(const(C)[] newValue)
    {
        breakText(newValue);
        return newValue;
    }

    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.declaration;
    }

    final const(C)[] standalone()
    {
        return getAttribute(toUTF!(string, S)(XmlConst.declarationStandaloneName));
    }

    final const(C)[] standalone(const(C)[] newValue)
    {
        checkStandalone(newValue);

        _innerText = null;
        if (newValue.length == 0)
            removeAttribute(toUTF!(string, S)(XmlConst.declarationStandaloneName));
        else
            setAttribute(toUTF!(string, S)(XmlConst.declarationStandaloneName), newValue);
        return newValue;
    }

    final override const(C)[] value()
    {
        return buildText();
    }

    final override const(C)[] value(const(C)[] newValue)
    {
        breakText(newValue);
        return newValue;
    }

    final const(C)[] versionStr()
    {
        return getAttribute(toUTF!(string, S)(XmlConst.declarationVersionName));
    }

    final const(C)[] versionStr(const(C)[] newValue)
    {
        _innerText = null;
        if (newValue.length == 0)
            removeAttribute(toUTF!(string, S)(XmlConst.declarationVersionName));
        else
            setAttribute(toUTF!(string, S)(XmlConst.declarationVersionName), newValue);
        return newValue;
    }
}

/** A xml document node object
*/
class XmlDocument(S) : XmlNode!S
{
public:
    alias EqualName = bool function(const(C)[] s1, const(C)[] s2);

protected:
    __gshared static XmlName!S _defaultQualifiedName;

    static XmlName!S createDefaultQualifiedName()
    {
        return new XmlName!S(toUTF!(string, S)(XmlConst.documentTagName));
    }

protected:
    XmlBufferList!(S, No.checkEncoded) _buffers;
    XmlEntityTable!S _entityTable;
    const(C)[][const(C)[]] _symbolTable;
    int _loading;

    pragma (inline, true)
    final XmlBuffer!(S, No.checkEncoded) acquireBuffer(XmlNodeType fromNodeType, size_t aCapacity = 0)
    {
        auto b = _buffers.acquire();
        if (aCapacity == 0 && fromNodeType == XmlNodeType.document)
            aCapacity = 64000;
        if (aCapacity != 0)
            b.capacity = aCapacity;

        return b;
    }

    pragma (inline, true)
    final S getAndReleaseBuffer(XmlBuffer!(S, No.checkEncoded) b)
    {
        return _buffers.getAndRelease(b);
    }

    final const(C)[] getDecodedText(ref XmlString!S s)
    {
        if (s.needDecode())
        {
            auto buffer = acquireBuffer(XmlNodeType.text, s.length);
            auto result = s.decodedText(buffer, decodeEntityTable());
            releaseBuffer(buffer);
            return result;
        }
        else
            return s.asValue();
    }

    final const(C)[] getEncodedText(ref XmlString!S s)
    {
        if (s.needEncode())
        {
            auto buffer = acquireBuffer(XmlNodeType.text, s.length);
            auto result = s.encodedText(buffer);
            releaseBuffer(buffer);
            return result;
        }
        else
            return s.asValue();
    }

    pragma (inline, true)
    final void releaseBuffer(XmlBuffer!(S, No.checkEncoded) b)
    {
        _buffers.release(b);
    }

    final override bool isLoading()
    {
        return _loading != 0;
    }

    final override XmlDocument!S selfOwnerDocument()
    {
        return this;
    }

package:
    final const(C)[] addSymbol(const(C)[] n)
    {
        auto e = n in _symbolTable;
        if (e is null)
        {
            _symbolTable[n] = n;
            e = n in _symbolTable;
        }
        return *e;
    }

    pragma (inline, true)
    final const(C)[] addSymbolIf(const(C)[] aSymbol)
    {
        if (aSymbol.length == 0 || !parseOptions.useSymbolTable)
            return aSymbol;
        else
            return addSymbol(aSymbol);
    }

    pragma (inline, true)
    final XmlName!S createName(const(C)[] aQualifiedName)
    {
        return new XmlName!S(this, aQualifiedName);
    }

    pragma (inline, true)
    final XmlName!S createName(const(C)[] aPrefix, const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        return new XmlName!S(this, aPrefix, aLocalName, aNamespaceUri);
    }

    final const(XmlEntityTable!S) decodeEntityTable()
    {
        if (_entityTable is null)
            return XmlEntityTable!S.defaultEntityTable();
        else
            return _entityTable;
    }

package:
    XmlDocumentTypeAttributeListDef!S createAttributeListDef(XmlDocumentTypeAttributeListDefType!S aDefType,
        const(C)[] aDefaultType, XmlString!S aDefaultText)
    {
        return new XmlDocumentTypeAttributeListDef!S(this, aDefType, aDefaultType, aDefaultText);
    }

    XmlDocumentTypeAttributeListDefType!S createAttributeListDefType(const(C)[] aName, const(C)[] aType,
        const(C)[][] aTypeItems)
    {
        return new XmlDocumentTypeAttributeListDefType!S(this, aName, aType, aTypeItems);
    }

    XmlAttribute!S createAttribute(const(C)[] aName, XmlString!S aText)
    {
        return new XmlAttribute!S(this, createName(aName), aText);
    }

    XmlComment!S createComment(XmlString!S aText)
    {
        return new XmlComment!S(this, aText);
    }

    XmlDocumentType!S createDocumentType(const(C)[] aName, const(C)[] aPublicOrSystem,
        XmlString!S aPublicId, XmlString!S aText)
    {
        return new XmlDocumentType!S(this, aName, aPublicOrSystem, aPublicId, aText);
    }

    XmlEntity!S createEntity(const(C)[] aName, XmlString!S aText)
    {
        return new XmlEntity!S(this, aName, aText);
    }

    XmlEntity!S createEntity(const(C)[] aName, const(C)[] aPublicOrSystem,
        XmlString!S aPublicId, XmlString!S aText, const(C)[] aNotationName)
    {
        return new XmlEntity!S(this, aName, aPublicOrSystem, aPublicId, aText, aNotationName);
    }

    XmlEntityReference!S createEntityReference(const(C)[] aName, XmlString!S aText)
    {
        return new XmlEntityReference!S(this, aName, aText);
    }

    XmlEntityReference!S createEntityReference(const(C)[] aName, const(C)[] aPublicOrSystem,
        XmlString!S aPublicId, XmlString!S aText)
    {
        return new XmlEntityReference!S(this, aName, aPublicOrSystem, aPublicId, aText);
    }

    XmlNotation!S createNotation(const(C)[] aName, const(C)[] aPublicOrSystem,
        XmlString!S aPublicId, XmlString!S aText)
    {
        return new XmlNotation!S(this, aName, aPublicOrSystem, aPublicId, aText);
    }

    XmlProcessingInstruction!S createProcessingInstruction(const(C)[] aTarget, XmlString!S aText)
    {
        return new XmlProcessingInstruction!S(this, aTarget, aText);
    }

    XmlText!S createText(XmlString!S aText)
    {
        return new XmlText!S(this, aText);
    }

public:
    /** A function pointer that is used for name comparision. This is allowed to be used
        to compare name without case-sensitive.
        Default is case-sensitive comparision
    */
    EqualName equalName;

    /** Default namespace value of this document
    */
    const(C)[] defaultUri;

    /** Parser options that control behavior while parsing
    */
    XmlParseOptions!S parseOptions;

    this()
    {
        equalName = &equalCase!S;
        _ownerDocument = null;
        _qualifiedName = singleton!(XmlName!S)(_defaultQualifiedName, &createDefaultQualifiedName);
        _buffers = new XmlBufferList!(S, No.checkEncoded)();
    }

    this(XmlParseOptions!S aParseOptions)
    {
        this();
        parseOptions = aParseOptions;
    }

    final override bool allowChild() const
    {
        return true;
    }

    final override bool allowChildType(XmlNodeType aNodeType)
    {
        switch (aNodeType)
        {
            case XmlNodeType.comment:
            case XmlNodeType.processingInstruction:
            case XmlNodeType.significantWhitespace:
            case XmlNodeType.whitespace:
                return true;
            case XmlNodeType.declaration:
                return documentDeclaration is null;
            case XmlNodeType.documentType:
                return documentType is null;
            case XmlNodeType.element:
                return documentElement is null;
            default:
                return false;
        }
    }

    /** Load a string xml, aXmlText, and returns its' document

        Params:
            aXmlText = a xml string

        Returns:
            self document instance
    */
    final XmlDocument!S load(const(C)[] aXmlText)
    {
        auto reader = new XmlStringReader!S(aXmlText);
        return load(reader);
    }

    /** Load a content xml from a xml reader, reader, and returns its' document

        Params:
            reader = a content xml reader

        Returns:
            self document instance
    */
    final XmlDocument!S load(XmlReader!S reader)
    {
        ++_loading;
        scope (exit)
            --_loading;

        removeAll();

        auto parser = XmlParser!S(this, reader);
        return parser.parse();
    }

    /** Load a content xml from a file-name, aFileName, and returns its' document

        Params:
            aFileName = a xml content file-name to be loaded from

        Returns:
            self document instance
    */
    final XmlDocument!S loadFromFile(string aFileName)
    {
        auto reader = new XmlFileReader!S(aFileName);
        scope (exit)
            reader.close();

        return load(reader);
    }

    static XmlDocument!S opCall(S aXmlText) 
    {
        auto doc = new XmlDocument!S();
		return doc.load(aXmlText);
	}

    static XmlDocument!S opCall(S aXmlText, in XmlParseOptions!S aParseOptions) 
    {
        auto doc = new XmlDocument!S(aParseOptions);
		return doc.load(aXmlText);
	}

    /** Write the document xml into a file-name, aFileName, and returns aFileName

        Params:
            aFileName = an actual file-name to be written to
            aPrettyOutput = indicates if xml should be in nicer format

        Returns:
            aFileName
    */
    final string saveToFile(string aFileName, Flag!"PrettyOutput" aPrettyOutput = No.PrettyOutput)
    {
        auto writer = new XmlFileWriter!S(aFileName, aPrettyOutput);
        scope (exit)
            writer.close();

        write(writer);
        return aFileName;
    }

    XmlAttribute!S createAttribute(const(C)[] aName)
    {
        return new XmlAttribute!S(this, createName(aName));
    }

    XmlAttribute!S createAttribute(const(C)[] aName, const(C)[] aValue)
    {
        return new XmlAttribute!S(this, createName(aName), aValue);
    }

    XmlAttribute!S createAttribute(const(C)[] aPrefix, const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        return new XmlAttribute!S(this, createName(aPrefix, aLocalName, aNamespaceUri));
    }

    XmlCData!S createCData(const(C)[] aData)
    {
        return new XmlCData!S(this, aData);
    }

    XmlComment!S createComment(const(C)[] aText)
    {
        return new XmlComment!S(this, aText);
    }

    XmlDeclaration!S createDeclaration()
    {
        return new XmlDeclaration!S(this);
    }

    XmlDeclaration!S createDeclaration(const(C)[] aVersionStr, const(C)[] aEncoding, const(C)[] aStandalone)
    {
        return new XmlDeclaration!S(this, aVersionStr, aEncoding, aStandalone);
    }

    XmlDocumentType!S createDocumentType(const(C)[] aName)
    {
        return new XmlDocumentType!S(this, aName);
    }

    XmlDocumentType!S createDocumentType(const(C)[] aName, const(C)[] aPublicOrSystem, const(C)[] aPublicId, const(C)[] aText)
    {
        return new XmlDocumentType!S(this, aName, aPublicOrSystem, aPublicId, aText);
    }

    XmlDocumentTypeAttributeList!S createDocumentTypeAttributeList(const(C)[] aName)
    {
        return new XmlDocumentTypeAttributeList!S(this, aName);
    }

    XmlDocumentTypeElement!S createDocumentTypeElement(const(C)[] aName)
    {
        return new XmlDocumentTypeElement!S(this, aName);
    }

    XmlElement!S createElement(const(C)[] aName)
    {
        return new XmlElement!S(this, createName(aName));
    }

    XmlElement!S createElement(const(C)[] aPrefix, const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        return new XmlElement!S(this, createName(aPrefix, aLocalName, aNamespaceUri));
    }

    XmlEntity!S createEntity(const(C)[] aName, const(C)[] aValue)
    {
        return new XmlEntity!S(this, aName, aValue);
    }

    XmlEntity!S createEntity(const(C)[] aName, const(C)[] aPublicOrSystem, const(C)[] aPublicId,
        const(C)[] aText, const(C)[] aNotationName)
    {
        return new XmlEntity!S(this, aName, aPublicOrSystem, aPublicId, aText, aNotationName);
    }

    XmlEntityReference!S createEntityReference(const(C)[] aName, const(C)[] aText)
    {
        return new XmlEntityReference!S(this, aName, aText);
    }

    XmlEntityReference!S createEntityReference(const(C)[] aName, const(C)[] aPublicOrSystem,
        const(C)[] aPublicId, const(C)[] aText)
    {
        return new XmlEntityReference!S(this, aName, aPublicOrSystem, aPublicId, aText);
    }

    XmlNotation!S createNotation(const(C)[] aName, const(C)[] aPublicOrSystem, const(C)[] aPublicId, const(C)[] aText)
    {
        return new XmlNotation!S(this, aName, aPublicOrSystem, aPublicId, aText);
    }

    XmlProcessingInstruction!S createProcessingInstruction(const(C)[] aTarget, const(C)[] aText)
    {
        return new XmlProcessingInstruction!S(this, aTarget, aText);
    }

    XmlSignificantWhitespace!S createSignificantWhitespace(const(C)[] aText)
    {
        return new XmlSignificantWhitespace!S(this, aText);
    }

    XmlText!S createText(const(C)[] aText)
    {
        return new XmlText!S(this, aText);
    }

    XmlWhitespace!S createWhitespace(const(C)[] aText)
    {
        return new XmlWhitespace!S(this, aText);
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        if (hasChildNodes)
            writeChildren(aWriter);

        return aWriter;
    }

@property:
    final override XmlDocument!S document()
    {
        return this;
    }

    final XmlDeclaration!S documentDeclaration()
    {
        return cast(XmlDeclaration!S) findChild(XmlNodeType.declaration);
    }

    final XmlElement!S documentElement()
    {
        return cast(XmlElement!S) findChild(XmlNodeType.element);
    }

    final XmlDocumentType!S documentType()
    {
        return cast(XmlDocumentType!S) findChild(XmlNodeType.documentType);
    }

    final XmlEntityTable!S entityTable()
    {
        if (_entityTable is null)
            _entityTable = new XmlEntityTable!S();
        return _entityTable;
    }

    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.document;
    }
}

/** A xml document-fragment node object
*/
class XmlDocumentFragment(S) : XmlNode!S
{
protected:
    static shared XmlName!S qualifiedName;
    static XmlName!S createQualifiedName()
    {
        return new XmlName!S(null, XmlConst.documentFragmentTagName);
    }

public:
    final override bool allowChild() const
    {
        return true;
    }

    final override bool allowChildType(XmlNodeType aNodeType)
    {
        switch (aNodeType)
        {
            case XmlNodeType.CData:
            case XmlNodeType.Comment:
            case XmlNodeType.Element:
            case XmlNodeType.Entity:
            case XmlNodeType.EntityReference:
            case XmlNodeType.Notation:
            case XmlNodeType.ProcessingInstruction:
            case XmlNodeType.SignificantWhitespace:
            case XmlNodeType.Text:
            case XmlNodeType.Whitespace:
                return true;
            default:
                return false;
        }
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        string msg = format(Message.eInvalidOpDelegate, shortClassName(this), "write()");
        throw new XmlInvalidOperationException(msg);
        //todo
        //return writer;
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.DocumentFragment;
    }
}

/** A xml document-type node object
*/
class XmlDocumentType(S) : XmlNode!S
{
protected:
    const(C)[] _publicOrSystem;
    XmlString!S _publicId;
    XmlString!S _text;

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName)
    {
        _ownerDocument = aOwnerDocument;
        _qualifiedName = new XmlName!S(aName);
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem,
        const(C)[] aPublicId, const(C)[] aText)
    {
        this(aOwnerDocument, aName);
        _publicOrSystem = aPublicOrSystem;
        _publicId = XmlString!S(aPublicId);
        _text = XmlString!S(aText);
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem,
        XmlString!S aPublicId, XmlString!S aText)
    {
        this(aOwnerDocument, aName);
        _publicOrSystem = aPublicOrSystem;
        _publicId = aPublicId;
        _text = aText;
    }

    final override bool allowChild() const
    {
        return true;
    }

    final override bool allowChildType(XmlNodeType aNodeType)
    {
        switch (aNodeType)
        {
            case XmlNodeType.comment:
            case XmlNodeType.documentTypeAttributeList:
            case XmlNodeType.documentTypeElement:
            case XmlNodeType.entity:
            case XmlNodeType.entityReference:
            case XmlNodeType.notation:
            case XmlNodeType.processingInstruction:
            case XmlNodeType.significantWhitespace:
            case XmlNodeType.text:
            case XmlNodeType.whitespace:
                return true;
            default:
                return false;
        }
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        Flag!"hasChild" c;
        if (hasChildNodes)
            c = Yes.hasChild;

        aWriter.putDocumentTypeBegin(name, publicOrSystem,
            ownerDocument.getEncodedText(_publicId), ownerDocument.getEncodedText(_text), c);
        if (c)
            writeChildren(aWriter);
        aWriter.putDocumentTypeEnd(c);

        return aWriter;
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.documentType;
    }

    final const(C)[] publicId()
    {
        return ownerDocument.getDecodedText(_publicId);
    }

    final const(C)[] publicId(const(C)[] newValue)
    {
        _publicId = newValue;
        return newValue;
    }

    final const(C)[] publicOrSystem()
    {
        return _publicOrSystem;
    }

    final const(C)[] publicOrSystem(const(C)[] newValue)
    {
        const equalName = document.equalName;
        if (newValue.length == 0 ||
            newValue == toUTF!(string, S)(XmlConst.public_) ||
            newValue == toUTF!(string, S)(XmlConst.system))
            return _publicOrSystem = newValue;
        else
            return null;
    }

    final override const(C)[] value()
    {
        return ownerDocument.getDecodedText(_text);
    }

    final override const(C)[] value(const(C)[] newValue)
    {
        _text = newValue;
        return newValue;
    }
}

class XmlDocumentTypeAttributeList(S) : XmlNode!S
{
protected:
    XmlDocumentTypeAttributeListDef!S[] _defs;

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName)
    {
        _ownerDocument = aOwnerDocument;
        _qualifiedName = new XmlName!S(aName);
    }

    final void appendDef(XmlDocumentTypeAttributeListDef!S aItem)
    {
        _defs ~= aItem;
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.putDocumentTypeAttributeListBegin(name);
        foreach (e; _defs)
            e.write(aWriter);
        aWriter.putDocumentTypeAttributeListEnd();

        return aWriter;
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.documentTypeAttributeList;
    }
}

class XmlDocumentTypeAttributeListDef(S) : XmlObject!S
{
protected:
    XmlDocument!S _ownerDocument;
    XmlDocumentTypeAttributeListDefType!S _type;
    XmlString!S _defaultDeclareText;
    const(C)[] _defaultDeclareType;

package:
    this(XmlDocument!S aOwnerDocument, XmlDocumentTypeAttributeListDefType!S aType,
        const(C)[] aDefaultDeclareType, XmlString!S aDefaultDeclareText)
    {
        _ownerDocument = aOwnerDocument;
        _type = aType;
        _defaultDeclareType = aDefaultDeclareType;
        _defaultDeclareText = aDefaultDeclareText;
    }

public:
    this(XmlDocument!S aOwnerDocument, XmlDocumentTypeAttributeListDefType!S aType,
        const(C)[] aDefaultDeclareType, const(C)[] aDefaultDeclareText)
    {
        this(aOwnerDocument, aType, aDefaultDeclareType, XmlString!S(aDefaultDeclareText));
    }

    final XmlWriter!S write(XmlWriter!S aWriter)
    {
        if (_type !is null)
            _type.write(aWriter);

        if (_defaultDeclareType.length > 0)
            aWriter.putWithPreSpace(_defaultDeclareType);

        if (_defaultDeclareText.length > 0)
        {
            aWriter.put(' ');
            aWriter.putWithQuote(ownerDocument.getEncodedText(_defaultDeclareText));
        }

        return aWriter;
    }

@property:
    final const(C)[] defaultDeclareText()
    {
        return ownerDocument.getDecodedText(_defaultDeclareText);
    }

    final const(C)[] defaultDeclareType()
    {
        return _defaultDeclareType;
    }

    final XmlDocument!S ownerDocument()
    {
        return _ownerDocument;
    }

    final XmlDocumentTypeAttributeListDefType!S type()
    {
        return _type;
    }
}

class XmlDocumentTypeAttributeListDefType(S) : XmlObject!S
{
protected:
    XmlDocument!S _ownerDocument;
    const(C)[] _name;
    const(C)[] _type;
    const(C)[][] _items;

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aType, const(C)[][] aItems)
    {
        _ownerDocument = aOwnerDocument;
        _name = aName;
        _type = aType;
        _items = aItems;
    }

    final void appendItem(const(C)[] aItem)
    {
        _items ~= aItem;
    }

    final XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.put(_name);
        aWriter.putWithPreSpace(_type);
        foreach (e; _items)
            aWriter.putWithPreSpace(e);

        return aWriter;
    }

@property:
    final const(C)[] localName()
    {
        return _name;
    }

    final const(C)[] name()
    {
        return _name;
    }

    final XmlDocument!S ownerDocument()
    {
        return _ownerDocument;
    }
}

class XmlDocumentTypeElement(S) : XmlNode!S
{
protected:
    XmlDocumentTypeElementItem!S[] _content;

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName)
    {
        _ownerDocument = aOwnerDocument;
        _qualifiedName = new XmlName!S(aName);
    }

    final XmlDocumentTypeElementItem!S appendChoice(const(C)[] aChoice)
    {
        XmlDocumentTypeElementItem!S item = new XmlDocumentTypeElementItem!S(ownerDocument, this, aChoice);
        _content ~= item;
        return item;
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.putDocumentTypeElementBegin(name);

        if (_content.length > 0)
        {
            if (_content.length > 1)
                aWriter.put('(');
            _content[0].write(aWriter);
            foreach (e; _content[1 .. $])
            {
                aWriter.put(',');
                e.write(aWriter);
            }
            if (_content.length > 1)
                aWriter.put(')');
        }

        aWriter.putDocumentTypeElementEnd();

        return aWriter;
    }

@property:
    final XmlDocumentTypeElementItem!S[] content()
    {
        return _content;
    }

    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.documentTypeElement;
    }
}

class XmlDocumentTypeElementItem(S) : XmlObject!S
{
protected:
    XmlDocument!S _ownerDocument;
    XmlNode!S _parent;
    XmlDocumentTypeElementItem!S[] _subChoices;
    const(C)[] _choice; // EMPTY | ANY | #PCDATA | any-name
    C _multiIndicator = 0; // * | ? | + | blank

public:
    this(XmlDocument!S aOwnerDocument, XmlNode!S aParent, const(C)[] aChoice)
    {
        _ownerDocument = aOwnerDocument;
        _parent = aParent;
        _choice = aChoice;
    }

    XmlDocumentTypeElementItem!S appendChoice(const(C)[] aChoice)
    {
        XmlDocumentTypeElementItem!S item = new XmlDocumentTypeElementItem!S(ownerDocument, parent, aChoice);
        _subChoices ~= item;
        return item;
    }

    final XmlWriter!S write(XmlWriter!S aWriter)
    {
        if (_choice.length > 0)
            aWriter.put(_choice);

        if (_subChoices.length > 0)
        {
            aWriter.put('(');
            _subChoices[0].write(aWriter);
            foreach (e; _subChoices[1 .. $])
            {
                aWriter.put('|');
                e.write(aWriter);
            }
            aWriter.put(')');
        }

        if (_multiIndicator != 0)
            aWriter.put(_multiIndicator);

        return aWriter;
    }

@property:
    final const(C)[] choice()
    {
        return _choice;
    }

    final C multiIndicator()
    {
        return _multiIndicator;
    }

    final C multiIndicator(C newValue)
    {
        return _multiIndicator = newValue;
    }

    final XmlDocument!S ownerDocument()
    {
        return _ownerDocument;
    }

    final XmlNode!S parent()
    {
        return _parent;
    }

    final XmlDocumentTypeElementItem!S[] subChoices()
    {
        return _subChoices;
    }
}

/** A xml element node object
*/
class XmlElement(S) : XmlNode!S
{
public:
    this(XmlDocument!S aOwnerDocument, XmlName!S aName)
    {
        if (!aOwnerDocument.isLoading())
        {
            checkName!(S, Yes.allowEmpty)(aName.prefix);
            checkName!(S, No.allowEmpty)(aName.localName);
        }

        _ownerDocument = aOwnerDocument;
        _qualifiedName = aName;
    }
    
    final override bool allowAttribute() const
    {
        return true;
    }

    final override bool allowChild() const
    {
        return true;
    }

    final override bool allowChildType(XmlNodeType aNodeType)
    {
        switch (aNodeType)
        {
            case XmlNodeType.CData:
            case XmlNodeType.comment:
            case XmlNodeType.element:
            case XmlNodeType.entityReference:
            case XmlNodeType.processingInstruction:
            case XmlNodeType.significantWhitespace:
            case XmlNodeType.text:
            case XmlNodeType.whitespace:
                return true;
            default:
                return false;
        }
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        Flag!"hasAttribute" a;
        if (hasAttributes)
            a = Yes.hasAttribute;

        Flag!"hasChild" c;
        if (hasChildNodes)
            c = Yes.hasChild;

        bool onlyOneNodeText = (isOnlyNode(firstChild) && firstChild.nodeType == XmlNodeType.text);
        if (onlyOneNodeText)
            aWriter.incOnlyOneNodeText();

        if (!a && !c)
            aWriter.putElementEmpty(name);
        else
        {
            aWriter.putElementNameBegin(name, a);

            if (a)
            {
                writeAttributes(aWriter);
                aWriter.putElementNameEnd(name, c);
            }

            if (c)
            {
                writeChildren(aWriter);
                aWriter.putElementEnd(name);
            }
        }

        if (onlyOneNodeText)
            aWriter.decOnlyOneNodeText();

        return aWriter;
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.element;
    }

    final override const(C)[] prefix(const(C)[] newValue)
    {
        _qualifiedName = ownerDocument.createName(newValue, localName, namespaceUri);
        return newValue;
    }
}

/** A xml entity node object
*/
class XmlEntity(S) : XmlEntityCustom!S
{
package:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName, XmlString!S aValue)
    {
        super(aOwnerDocument, aName, aValue);
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem,
        XmlString!S aPublicId, XmlString!S aValue, const(C)[] aNotationName)
    {
        super(aOwnerDocument, aName, aPublicOrSystem, aPublicId, aValue, aNotationName);
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aValue)
    {
        super(aOwnerDocument, aName, aValue);
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem, const(C)[] aPublicId,
        const(C)[] aValue, const(C)[] aNotationName)
    {
        super(aOwnerDocument, aName, aPublicOrSystem, aPublicId, aValue, aNotationName);
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.putEntityGeneral(name, _publicOrSystem, ownerDocument.getEncodedText(_publicId),
            _notationName, ownerDocument.getEncodedText(_text));

        return aWriter;
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.entity;
    }
}

/** A xml entity-reference node object
*/
class XmlEntityReference(S) : XmlEntityCustom!S
{
package:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName, XmlString!S aValue)
    {
        super(aOwnerDocument, aName, aValue);
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem,
        XmlString!S aPublicId, XmlString!S aValue)
    {
        super(aOwnerDocument, aName, aPublicOrSystem, aPublicId, aValue, null);
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aValue)
    {
        super(aOwnerDocument, aName, aValue);
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem, const(C)[] aPublicId, const(C)[] aValue)
    {
        super(aOwnerDocument, aName, aPublicOrSystem, aPublicId, aValue, null);
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.putEntityReference(name, _publicOrSystem, ownerDocument.getEncodedText(_publicId),
            _notationName, ownerDocument.getEncodedText(_text));

        return aWriter;
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.entityReference;
    }
}

/** A xml annotation node object
*/
class XmlNotation(S) : XmlNode!S
{
protected:
    const(C)[] _publicOrSystem;
    XmlString!S _publicId;
    XmlString!S _text;

    this(XmlDocument!S aOwnerDocument, const(C)[] aName)
    {
        _ownerDocument = aOwnerDocument;
        _qualifiedName = new XmlName!S(aName);
    }

package:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem,
        XmlString!S aPublicId, XmlString!S aText)
    {
        this(aOwnerDocument, aName);
        _publicOrSystem = aPublicOrSystem;
        _publicId = aPublicId;
        _text = aText;
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem,
        const(C)[] aPublicId, const(C)[] aText)
    {
        this(aOwnerDocument, aName);
        _publicOrSystem = aPublicOrSystem;
        _publicId = XmlString!S(aPublicId);
        _text = XmlString!S(aText);
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.putNotation(name, publicOrSystem, ownerDocument.getEncodedText(_publicId),
            ownerDocument.getEncodedText(_text));

        return aWriter;
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.notation;
    }

    final const(C)[] publicId()
    {
        return ownerDocument.getDecodedText(_publicId);
    }

    final const(C)[] publicOrSystem()
    {
        return _publicOrSystem;
    }

    final override const(C)[] value()
    {
        return ownerDocument.getDecodedText(_text);
    }

    final override const(C)[] value(const(C)[] newValue)
    {
        _text = newValue;
        return newValue;
    }
}

/** A xml processing-instruction node object
*/
class XmlProcessingInstruction(S) : XmlNode!S
{
protected:
    XmlString!S _text;

    this(XmlDocument!S aOwnerDocument, const(C)[] aTarget)
    {
        _ownerDocument = aOwnerDocument;
        _qualifiedName = new XmlName!S(aTarget);
    }

package:
    this(XmlDocument!S aOwnerDocument, const(C)[] aTarget, XmlString!S aText)
    {
        this(aOwnerDocument, aTarget);
        _text = aText;
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aTarget, const(C)[] aText)
    {
        this(aOwnerDocument, aTarget);
        _text = XmlString!S(aText);
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.putProcessingInstruction(name, ownerDocument.getEncodedText(_text));

        return aWriter;
    }

@property:
    final override const(C)[] innerText()
    {
        return value;
    }

    final override const(C)[] innerText(const(C)[] newValue)
    {
        return value(newValue);
    }

    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.processingInstruction;
    }

    final const(C)[] target()
    {
        return _qualifiedName.name;
    }

    final override const(C)[] value()
    {
        return ownerDocument.getDecodedText(_text); 
    }

    final override const(C)[] value(const(C)[] newValue)
    {
        _text = newValue;
        return newValue;
    }
}

/** A xml significant-whitespace node object
*/
class XmlSignificantWhitespace(S) : XmlCharacterWhitespace!S
{
protected:
    __gshared static XmlName!S _defaultQualifiedName;

    static XmlName!S createDefaultQualifiedName()
    {
        return new XmlName!S(toUTF!(string, S)(XmlConst.significantWhitespaceTagName));
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aText)
    {
        super(aOwnerDocument, aText);
        _qualifiedName = singleton!(XmlName!S)(_defaultQualifiedName, &createDefaultQualifiedName);
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.significantWhitespace;
    }
}

/** A xml text node object
*/
class XmlText(S) : XmlCharacterDataCustom!S
{
protected:
    __gshared static XmlName!S _defaultQualifiedName;

    static XmlName!S createDefaultQualifiedName()
    {
        return new XmlName!S(toUTF!(string, S)(XmlConst.textTagName));
    }

package:
    this(XmlDocument!S aOwnerDocument, XmlString!S aText)
    {
        super(aOwnerDocument, aText);
        _qualifiedName = singleton!(XmlName!S)(_defaultQualifiedName, &createDefaultQualifiedName);
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aText)
    {
        super(aOwnerDocument, aText);
        _qualifiedName = singleton!(XmlName!S)(_defaultQualifiedName, &createDefaultQualifiedName);
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        aWriter.put(ownerDocument.getEncodedText(_text));

        return aWriter;
    }

@property:
    final override size_t level()
    {
        if (parentNode is null)
            return 0;
        else
            return parentNode.level;
    }

    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.text;
    }
}

/** A xml whitespace node object
*/
class XmlWhitespace(S) : XmlCharacterWhitespace!S
{
protected:
    __gshared static XmlName!S _defaultQualifiedName;

    static XmlName!S createDefaultQualifiedName()
    {
        return new XmlName!S(toUTF!(string, S)(XmlConst.whitespaceTagName));
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aText)
    {
        super(aOwnerDocument, aText);
        _qualifiedName = singleton!(XmlName!S)(_defaultQualifiedName, &createDefaultQualifiedName);
    }

@property:
    final override XmlNodeType nodeType() const
    {
        return XmlNodeType.whitespace;
    }
}

/** A xml custom node object for any text type node object
*/
class XmlCharacterDataCustom(S) : XmlNode!S
{
protected:
    XmlString!S _text;

    final override bool isText() const
    {
        return true;
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aText)
    {
        this(aOwnerDocument, XmlString!S(aText, XmlEncodeMode.check));
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aText, XmlEncodeMode aMode)
    {
        this(aOwnerDocument, XmlString!S(aText, aMode));
    }

    this(XmlDocument!S aOwnerDocument, XmlString!S aText)
    {
        _ownerDocument = aOwnerDocument;
        _text = aText;
    }

public:
@property:
    final override const(C)[] innerText()
    {
        return value;
    }

    final override const(C)[] innerText(const(C)[] newValue)
    {
        return value(newValue);
    }

    override const(C)[] value()
    {
        return ownerDocument.getDecodedText(_text);
    }

    override const(C)[] value(const(C)[] newValue)
    {
        _text = newValue;
        return newValue;
    }
}

/** A xml custom node object for whitespace or significant-whitespace node object
*/
class XmlCharacterWhitespace(S) : XmlCharacterDataCustom!S
{
protected:
    final const(C)[] checkWhitespaces(const(C)[] aText)
    {
        if (!isSpaces!S(aText))
            throw new XmlException(Message.eNotAllWhitespaces);
        return aText;
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aText)
    {
        if (!aOwnerDocument.isLoading())
            checkWhitespaces(aText);

        super(aOwnerDocument, XmlString!S(aText, XmlEncodeMode.none));
    }

    final override XmlWriter!S write(XmlWriter!S aWriter)
    {
        if (_text.length > 0)
            aWriter.put(_text.value);

        return aWriter;
    }

@property:
    final override size_t level()
    {
        if (parentNode is null)
            return 0;
        else
            return parentNode.level;
    }

    final override const(C)[] value()
    {
        return _text.asValue();
    }

    final override const(C)[] value(const(C)[] newValue)
    {
        _text = checkWhitespaces(newValue);
        return newValue;
    }
}

/** A xml custom node object for entity or entity-reference node object
*/
class XmlEntityCustom(S) : XmlNode!S
{
protected:
    const(C)[] _notationName;
    const(C)[] _publicOrSystem;
    XmlString!S _publicId;
    XmlString!S _text;

    this(XmlDocument!S aOwnerDocument, const(C)[] aName)
    {
        _ownerDocument = aOwnerDocument;
        _qualifiedName = new XmlName!S(aName);
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aName, XmlString!S aText)
    {
        this(aOwnerDocument, aName);
        _text = aText;
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem,
        XmlString!S aPublicId, XmlString!S aText, const(C)[] aNotationName)
    {
        this(aOwnerDocument, aName);
        _publicOrSystem = aPublicOrSystem;
        _publicId = aPublicId;
        _text = aText;
        _notationName = aNotationName;
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aText)
    {
        this(aOwnerDocument, aName);
        _text = XmlString!S(aText);
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aName, const(C)[] aPublicOrSystem, const(C)[] aPublicId,
        const(C)[] aText, const(C)[] aNotationName)
    {
        this(aOwnerDocument, aName);
        _publicOrSystem = aPublicOrSystem;
        _publicId = XmlString!S(aPublicId);
        _text = XmlString!S(aText);
        _notationName = aNotationName;
    }

@property:
    final const(C)[] notationName()
    {
        return _notationName;
    }

    final const(C)[] publicId()
    {
        return ownerDocument.getDecodedText(_publicId);
    }

    final const(C)[] publicOrSystem()
    {
        return _publicOrSystem;
    }

    final override const(C)[] value()
    {
        return ownerDocument.getDecodedText(_text);
    }

    final override const(C)[] value(const(C)[] newValue)
    {
        _text = newValue;
        return newValue;
    }
}

/** A xml name object
*/
class XmlName(S) : XmlObject!S
{
protected:
    XmlDocument!S ownerDocument;
    const(C)[] _localName;
    const(C)[] _name;
    const(C)[] _namespaceUri;
    const(C)[] _prefix;

package:
    this(const(C)[] aStaticName)
    {
        _localName = aStaticName;
        _name = aStaticName;
        _namespaceUri = "";
        _prefix = "";
    }

public:
    this(XmlDocument!S aOwnerDocument, const(C)[] aPrefix, const(C)[] aLocalName, const(C)[] aNamespaceUri)
    {
        ownerDocument = aOwnerDocument;

        _localName = aOwnerDocument.addSymbolIf(aLocalName);
        _namespaceUri = aOwnerDocument.addSymbolIf(aNamespaceUri);
        _prefix = aOwnerDocument.addSymbolIf(aPrefix);

        if (aPrefix.length == 0)
            _name = aLocalName;
    }

    this(XmlDocument!S aOwnerDocument, const(C)[] aQualifiedName)
    {
        ownerDocument = aOwnerDocument;

        _name = aOwnerDocument.addSymbolIf(aQualifiedName);
    }

@property:
    final const(C)[] localName()
    {
        if (_localName.ptr is null)
            splitName!S(name, _prefix, _localName);

        return _localName;
    }

    final const(C)[] name()
    {
        if (_name.ptr is null)
        {
            if (ownerDocument is null)
                _name = combineName!S(prefix, localName);
            else
                _name = ownerDocument.addSymbolIf(combineName!S(prefix, localName));
        }

        return _name;
    }

    final const(C)[] namespaceUri()
    {
        if (_namespaceUri.ptr is null)
        {
            if ((toUTF!(string, S)(XmlConst.xmlns) == prefix) || 
                (prefix.length == 0 && toUTF!(string, S)(XmlConst.xmlns) == localName))
                _namespaceUri = toUTF!(string, S)(XmlConst.xmlnsNS);
            else if (toUTF!(string, S)(XmlConst.xml) == prefix)
                _namespaceUri = toUTF!(string, S)(XmlConst.xmlNS);
            else if (ownerDocument !is null)
                _namespaceUri = ownerDocument.defaultUri;
            else
                _namespaceUri = "";
        }

        return _namespaceUri;
    }

    final const(C)[] prefix()
    {
        if (_prefix.ptr is null && _localName.length == 0)
            splitName!S(name, _prefix, _localName);

        return _prefix;
    }
}

unittest  // Display object sizeof
{
    import std.conv : to;

    outputXmlTraceProgress("");
    outputXmlTraceProgress("XmlNodeList.sizeof: " ~ to!string(XmlNodeList!string.sizeof));
    outputXmlTraceProgress("XmlAttribute.sizeof: " ~ to!string(XmlAttribute!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlCData.sizeof: " ~ to!string(XmlCData!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlComment.sizeof: " ~ to!string(XmlComment!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlDeclaration.sizeof: " ~ to!string(XmlDeclaration!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlDocument.sizeof: " ~ to!string(XmlDocument!string.classinfo.initializer.length));
    //outputXmlTraceProgress("XmlDocumentFragment.sizeof: " ~ to!string(XmlDocumentFragment!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlDocumentType.sizeof: " ~ to!string(XmlDocumentType!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlDocumentTypeAttributeList.sizeof: " ~ to!string(XmlDocumentTypeAttributeList!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlDocumentTypeAttributeListDef.sizeof: " ~ to!string(XmlDocumentTypeAttributeListDef!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlDocumentTypeAttributeListDefType.sizeof: " ~ to!string(XmlDocumentTypeAttributeListDefType!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlDocumentTypeElement.sizeof: " ~ to!string(XmlDocumentTypeElement!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlDocumentTypeElementItem.sizeof: " ~ to!string(XmlDocumentTypeElementItem!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlElement.sizeof: " ~ to!string(XmlElement!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlEntity.sizeof: " ~ to!string(XmlEntity!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlEntityReference.sizeof: " ~ to!string(XmlEntityReference!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlNotation.sizeof: " ~ to!string(XmlNotation!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlProcessingInstruction.sizeof: " ~ to!string(XmlProcessingInstruction!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlSignificantWhitespace.sizeof: " ~ to!string(XmlSignificantWhitespace!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlText.sizeof: " ~ to!string(XmlText!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlWhitespace.sizeof: " ~ to!string(XmlWhitespace!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlCharacterWhitespace.sizeof: " ~ to!string(XmlCharacterWhitespace!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlName.sizeof: " ~ to!string(XmlName!string.classinfo.initializer.length));
    outputXmlTraceProgress("XmlParser.sizeof: " ~ to!string(XmlParser!string.sizeof));
    outputXmlTraceProgress("XmlString.sizeof: " ~ to!string(XmlString!string.sizeof));
    outputXmlTraceProgress("XmlBuffer.sizeof: " ~ to!string(XmlBuffer!(string, No.checkEncoded).classinfo.initializer.length));
    outputXmlTraceProgress("XmlBufferList.sizeof: " ~ to!string(XmlBufferList!(string, No.checkEncoded).classinfo.initializer.length));
    outputXmlTraceProgress("");
}

unittest  // XmlDocument
{
    outputXmlTraceProgress("unittest XmlDocument");

    auto doc = new XmlDocument!string();
    auto root = doc.appendChild(doc.createElement("root"));
    root.appendChild(doc.createElement("prefix", "localname", null));
    root.appendChild(doc.createElement("a"))
        .appendAttribute(doc.createAttribute("a", "value"));
    root.appendChild(doc.createElement("a2"))
        .appendAttribute(doc.createAttribute("a2", "&<>'\""));
    root.appendChild(doc.createElement("c"))
        .appendChild(doc.createComment("--comment--"));
    root.appendChild(doc.createElement("t"))
        .appendChild(doc.createText("text"));
    root.appendChild(doc.createCData("data &<>"));

    static immutable string res = "<root><prefix:localname/><a a=\"value\"/><a2 a2=\"&amp;&lt;&gt;&apos;&quot;\"/><c><!----comment----></c><t>text</t><![CDATA[data &<>]]></root>";

    assert(doc.outerXml() == res);

    doc = XmlDocument!string(res);
    assert(doc.outerXml() == res);
}