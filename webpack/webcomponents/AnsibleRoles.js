import React from 'react';
import { mountNode } from 'foremanReact/common/MountingService';

export default class AnsibleRolesElement extends HTMLElement {
  connectedCallback() {
    const mountPoint = document.createElement('span');
    this.appendChild(mountPoint);
    const data = JSON.parse(this.dataset.roles);

    mountNode('AnsibleRolesSwitcher', mountPoint, data);
  }
};
